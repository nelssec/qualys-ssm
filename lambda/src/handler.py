"""
Qualys SSM Scanner - Lambda Trigger Function

Triggers QScanner rootfs scans on EC2 instances via SSM Run Command.

Event Sources:
- EventBridge: EC2 Instance State-change (running)
- EventBridge: Scheduled event (fleet scan)
- Manual: Direct Lambda invocation
"""

import boto3
import json
import os
import logging
from datetime import datetime, timedelta

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients
ssm = boto3.client('ssm')
ec2 = boto3.client('ec2')

# Environment variables
SSM_DOCUMENT_NAME = os.environ.get('SSM_DOCUMENT_NAME', 'Qualys-RootFS-Scan')
QUALYS_POD = os.environ.get('QUALYS_POD', 'US2')
SCAN_TYPES = os.environ.get('SCAN_TYPES', 'os,sca,fileinsight')
S3_BUCKET = os.environ.get('S3_BUCKET', '')
SECRET_NAME = os.environ.get('SECRET_NAME', 'qualys/qscanner-token')
EXCLUDE_DIRS = os.environ.get('EXCLUDE_DIRS', '/proc,/sys,/dev,/run,/tmp,/var/lib/docker')
MAX_CONCURRENCY = os.environ.get('MAX_CONCURRENCY', '10')
MAX_ERRORS = os.environ.get('MAX_ERRORS', '25%')
SCAN_MODE = os.environ.get('SCAN_MODE', 'get-report')

# Delay for new instances (wait for SSM agent)
NEW_INSTANCE_DELAY_SECONDS = int(os.environ.get('NEW_INSTANCE_DELAY_SECONDS', '60'))


def handler(event, context):
    """Main Lambda handler."""
    logger.info(f"Received event: {json.dumps(event)}")

    try:
        # Determine event type and get target instances
        event_type, instance_ids = parse_event(event)
        logger.info(f"Event type: {event_type}, Target instances: {instance_ids}")

        if not instance_ids:
            return response(200, 'no_targets', 'No instances to scan')

        # For new EC2 events, check if we should delay
        if event_type == 'new_ec2':
            # Check if instance has SSM agent ready
            ready_instances = wait_for_ssm_ready(instance_ids, max_wait=NEW_INSTANCE_DELAY_SECONDS)
        else:
            ready_instances = check_ssm_ready(instance_ids)

        if not ready_instances:
            logger.warning(f"No instances ready for scanning: {instance_ids}")
            return response(200, 'not_ready', 'No instances with SSM agent ready')

        # Send SSM command
        command_id = send_scan_command(ready_instances)

        return response(200, 'started', f'Scan started for {len(ready_instances)} instances', {
            'commandId': command_id,
            'targetCount': len(ready_instances),
            'instances': ready_instances,
            'eventType': event_type
        })

    except Exception as e:
        logger.exception(f"Error processing event: {e}")
        return response(500, 'error', str(e))


def parse_event(event):
    """Parse incoming event and extract target instance IDs."""

    # EC2 State Change Event (new instance running)
    if event.get('detail-type') == 'EC2 Instance State-change Notification':
        instance_id = event['detail']['instance-id']
        state = event['detail']['state']

        if state != 'running':
            logger.info(f"Instance {instance_id} state is {state}, skipping")
            return 'ec2_state_change', []

        # Check if instance should be scanned
        if not should_scan_instance(instance_id):
            logger.info(f"Instance {instance_id} excluded from scanning")
            return 'new_ec2', []

        return 'new_ec2', [instance_id]

    # Scheduled Event (fleet scan)
    if event.get('detail-type') == 'Scheduled Event':
        instances = get_scannable_instances()
        return 'scheduled', instances

    # Manual invocation with specific instances
    if 'instance_ids' in event:
        return 'manual', event['instance_ids']

    # Manual invocation - fleet scan
    if event.get('scan_type') == 'fleet':
        instances = get_scannable_instances()
        return 'fleet', instances

    # Manual invocation - all running instances
    if event.get('scan_type') == 'all':
        instances = get_all_running_instances()
        return 'all', instances

    # Default: no targets
    return 'unknown', []


def should_scan_instance(instance_id):
    """Check if instance should be scanned based on tags."""
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])

        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}

                # Skip if explicitly disabled
                if tags.get('QualysScan', '').lower() == 'disabled':
                    return False

                # Skip if it's a spot instance being terminated
                if instance.get('InstanceLifecycle') == 'spot':
                    state = instance.get('State', {}).get('Name')
                    if state in ['shutting-down', 'terminated']:
                        return False

        return True

    except Exception as e:
        logger.warning(f"Error checking instance {instance_id}: {e}")
        return True  # Default to scanning


def get_scannable_instances():
    """Get instances tagged for Qualys scanning."""
    try:
        response = ec2.describe_instances(
            Filters=[
                {'Name': 'instance-state-name', 'Values': ['running']},
                {'Name': 'tag:QualysScan', 'Values': ['enabled', 'true', 'yes', '1']}
            ]
        )

        instances = []
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                instances.append(instance['InstanceId'])

        logger.info(f"Found {len(instances)} tagged instances for scanning")
        return instances

    except Exception as e:
        logger.error(f"Error getting scannable instances: {e}")
        return []


def get_all_running_instances():
    """Get all running EC2 instances."""
    try:
        instances = []
        paginator = ec2.get_paginator('describe_instances')

        for page in paginator.paginate(
            Filters=[{'Name': 'instance-state-name', 'Values': ['running']}]
        ):
            for reservation in page['Reservations']:
                for instance in reservation['Instances']:
                    # Skip if explicitly disabled
                    tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}
                    if tags.get('QualysScan', '').lower() != 'disabled':
                        instances.append(instance['InstanceId'])

        logger.info(f"Found {len(instances)} running instances")
        return instances

    except Exception as e:
        logger.error(f"Error getting running instances: {e}")
        return []


def check_ssm_ready(instance_ids):
    """Filter instances to only those with SSM agent online."""
    if not instance_ids:
        return []

    try:
        ready = []
        # SSM has a limit of 50 instances per request
        for i in range(0, len(instance_ids), 50):
            batch = instance_ids[i:i+50]
            response = ssm.describe_instance_information(
                Filters=[{'Key': 'InstanceIds', 'Values': batch}]
            )

            for info in response['InstanceInformationList']:
                if info['PingStatus'] == 'Online':
                    ready.append(info['InstanceId'])

        logger.info(f"SSM ready: {len(ready)}/{len(instance_ids)} instances")
        return ready

    except Exception as e:
        logger.error(f"Error checking SSM status: {e}")
        return []


def wait_for_ssm_ready(instance_ids, max_wait=60):
    """Wait for SSM agent to become ready on new instances."""
    import time

    logger.info(f"Waiting up to {max_wait}s for SSM agent on {instance_ids}")

    start_time = time.time()
    check_interval = 10  # seconds

    while time.time() - start_time < max_wait:
        ready = check_ssm_ready(instance_ids)
        if ready:
            return ready

        remaining = max_wait - (time.time() - start_time)
        if remaining > check_interval:
            logger.info(f"SSM not ready, waiting {check_interval}s...")
            time.sleep(check_interval)
        else:
            break

    # Final check
    return check_ssm_ready(instance_ids)


def send_scan_command(instance_ids):
    """Send SSM Run Command to trigger scans."""
    logger.info(f"Sending scan command to {len(instance_ids)} instances")

    response = ssm.send_command(
        InstanceIds=instance_ids,
        DocumentName=SSM_DOCUMENT_NAME,
        Parameters={
            'Pod': [QUALYS_POD],
            'ScanTypes': [SCAN_TYPES],
            'ExcludeDirs': [EXCLUDE_DIRS],
            'S3Bucket': [S3_BUCKET],
            'SecretName': [SECRET_NAME],
            'ScanMode': [SCAN_MODE]
        },
        TimeoutSeconds=900,
        MaxConcurrency=MAX_CONCURRENCY,
        MaxErrors=MAX_ERRORS,
        CloudWatchOutputConfig={
            'CloudWatchLogGroupName': f'/aws/ssm/{SSM_DOCUMENT_NAME}',
            'CloudWatchOutputEnabled': True
        }
    )

    command_id = response['Command']['CommandId']
    logger.info(f"SSM Command started: {command_id}")

    return command_id


def response(status_code, status, message, data=None):
    """Build response object."""
    body = {
        'status': status,
        'message': message,
        'timestamp': datetime.utcnow().isoformat()
    }

    if data:
        body.update(data)

    return {
        'statusCode': status_code,
        'body': json.dumps(body)
    }
