#!/usr/bin/env python3
import os
import time
import logging
import psutil
import json
import subprocess
import requests
from google.oauth2 import service_account
from googleapiclient import discovery

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("auto_scaler.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("auto_scaler")

# Configuration
THRESHOLD_CPU = 75.0       # CPU threshold percentage
THRESHOLD_MEMORY = 75.0    # Memory threshold percentage
CHECK_INTERVAL = 5         # Seconds between checks
CONSECUTIVE_THRESHOLD_VIOLATIONS = 3  # Number of consecutive violations before scaling
GCP_CREDENTIALS_FILE = os.path.expanduser('~/auto-scale-project/gcp-credentials.json')
GCP_PROJECT_ID = None      # Will be set from credentials
GCP_ZONE = 'us-central1-a' # Default zone
GCP_MACHINE_TYPE = 'e2-micro'
LOCAL_APP_PORT = 5000
VM_NAME = 'auto-scaled-vm'
STARTUP_SCRIPT_PATH = os.path.expanduser('~/auto-scale-project/gcp/startup-script.sh')

class AutoScaler:
    def __init__(self):
        self.violation_count = 0
        self.gcp_vm_created = False
        self.gcp_vm_ip = None
        self.migration_complete = False
        self.health_check_failures = 0
        self.max_health_check_failures = 3
        
        # Set project ID from credentials
        global GCP_PROJECT_ID
        with open(GCP_CREDENTIALS_FILE, 'r') as f:
            cred_data = json.load(f)
            GCP_PROJECT_ID = cred_data.get('project_id')
            if not GCP_PROJECT_ID:
                logger.error("Could not determine GCP Project ID from credentials")
                exit(1)
        
        logger.info(f"Initialized auto-scaler for project {GCP_PROJECT_ID}")
        
        # Initialize GCP compute client
        self.compute = self._get_compute_client()
    
    def _get_compute_client(self):
        """Create and return a GCP compute client with retries."""
        max_retries = 3
        retry_delay = 5  # seconds
        
        for attempt in range(max_retries):
            try:
                credentials = service_account.Credentials.from_service_account_file(
                    GCP_CREDENTIALS_FILE,
                    scopes=['https://www.googleapis.com/auth/cloud-platform']
                )
                return discovery.build('compute', 'v1', credentials=credentials)
            except ConnectionError as e:
                if attempt < max_retries - 1:
                    logger.warning(f"Connection error on attempt {attempt+1}/{max_retries}. Retrying in {retry_delay}s: {e}")
                    time.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                else:
                    logger.error(f"Failed to create GCP compute client after {max_retries} attempts: {e}")
                    return None
            except Exception as e:
                logger.error(f"Failed to create GCP compute client: {e}")
                return None
    
    def check_vm_exists(self):
        """Check if the GCP VM still exists."""
        if not self.compute or not self.gcp_vm_created or not self.gcp_vm_ip:
            return False
        
        try:
            self.compute.instances().get(
                project=GCP_PROJECT_ID,
                zone=GCP_ZONE,
                instance=VM_NAME
            ).execute()
            return True
        except Exception as e:
            # If we get a 404 error, the VM doesn't exist
            if "was not found" in str(e):
                logger.warning(f"VM {VM_NAME} was not found, it may have been deleted")
                # Reset state to allow new VM creation
                self.gcp_vm_created = False
                self.gcp_vm_ip = None
                self.migration_complete = False
                return False
            # For other errors, log but assume VM exists
            logger.error(f"Error checking if VM exists: {e}")
            return True
    
    def check_resource_usage(self):
        """Check if CPU or memory usage exceeds thresholds."""
        # First check if VM still exists if we think we've created one
        if self.gcp_vm_created:
            if not self.check_vm_exists():
                logger.warning("Previously created VM no longer exists. Will create a new one when needed.")
        
        cpu_percent = psutil.cpu_percent(interval=1)
        memory_percent = psutil.virtual_memory().percent
        
        logger.info(f"Current CPU: {cpu_percent}%, Memory: {memory_percent}%")
        
        if cpu_percent > THRESHOLD_CPU or memory_percent > THRESHOLD_MEMORY:
            self.violation_count += 1
            logger.warning(f"Threshold violation detected ({self.violation_count}/{CONSECUTIVE_THRESHOLD_VIOLATIONS})")
            
            if self.violation_count >= CONSECUTIVE_THRESHOLD_VIOLATIONS:
                if not self.gcp_vm_created:
                    logger.warning("Multiple threshold violations detected! Initiating scale-out to GCP...")
                    self.create_gcp_vm()
                elif not self.migration_complete:
                    self.check_vm_readiness()
        else:
            # Reset violation count if resources are below threshold
            if self.violation_count > 0:
                logger.info("Resource usage returned below threshold")
                self.violation_count = 0
    
    def create_gcp_vm(self):
        """Create a VM in GCP for scaling with improved error handling."""
        if not self.compute:
            logger.error("GCP compute client not initialized")
            return
        
        try:
            # Read startup script
            with open(STARTUP_SCRIPT_PATH, 'r') as f:
                startup_script = f.read()
            
            # Prepare the VM configuration
            config = {
                'name': VM_NAME,
                'machineType': f'zones/{GCP_ZONE}/machineTypes/{GCP_MACHINE_TYPE}',
                'disks': [{
                    'boot': True,
                    'autoDelete': True,
                    'initializeParams': {
                        'sourceImage': 'projects/debian-cloud/global/images/family/debian-11'
                    }
                }],
                'networkInterfaces': [{
                    'network': 'global/networks/default',
                    'accessConfigs': [{'type': 'ONE_TO_ONE_NAT', 'name': 'External NAT'}]
                }],
                'metadata': {
                    'items': [
                        {
                            'key': 'startup-script',
                            'value': startup_script
                        },
                        {
                            'key': 'enable-oslogin',
                            'value': 'TRUE'  # Enable OS Login for SSH access
                        }
                    ]
                },
                'serviceAccounts': [{
                    'email': f'auto-scaler@{GCP_PROJECT_ID}.iam.gserviceaccount.com',
                    'scopes': [
                        'https://www.googleapis.com/auth/compute',
                        'https://www.googleapis.com/auth/devstorage.read_write',
                        'https://www.googleapis.com/auth/logging.write',
                        'https://www.googleapis.com/auth/monitoring.write'
                    ]
                }],
                'tags': {
                    'items': ['http-server', 'https-server']
                }
            }
            
            logger.info(f"Attempting to create VM in project {GCP_PROJECT_ID}, zone {GCP_ZONE}")
            
            # Create the VM
            operation = self.compute.instances().insert(
                project=GCP_PROJECT_ID,
                zone=GCP_ZONE,
                body=config
            ).execute()
            
            logger.info(f"VM creation initiated with operation {operation['name']}")
            self.gcp_vm_created = True
            
            # Wait for the operation to complete
            if self._wait_for_operation(operation['name']):
                # Get the VM details to extract the IP
                vm_info = self.compute.instances().get(
                    project=GCP_PROJECT_ID, 
                    zone=GCP_ZONE, 
                    instance=VM_NAME
                ).execute()
                
                # Extract the external IP
                for interface in vm_info['networkInterfaces']:
                    for config in interface.get('accessConfigs', []):
                        if config.get('natIP'):
                            self.gcp_vm_ip = config['natIP']
                            break
                
                if self.gcp_vm_ip:
                    logger.info(f"VM created successfully with IP: {self.gcp_vm_ip}")
                else:
                    logger.error("VM created but could not determine IP address")
            else:
                self.gcp_vm_created = False
                
        except ConnectionError as e:
            logger.error(f"Network error when creating GCP VM: {e}")
            logger.info("Check your internet connection and firewall settings")
            self.gcp_vm_created = False
        except Exception as e:
            logger.error(f"Failed to create GCP VM: {e}")
            self.gcp_vm_created = False
    
    def _wait_for_operation(self, operation_name):
        """Wait for a GCP operation to complete."""
        logger.info(f"Waiting for operation {operation_name} to complete...")
        
        while True:
            result = self.compute.zoneOperations().get(
                project=GCP_PROJECT_ID,
                zone=GCP_ZONE,
                operation=operation_name
            ).execute()
            
            if result['status'] == 'DONE':
                if 'error' in result:
                    logger.error(f"Operation failed: {result['error']}")
                    return False
                logger.info("Operation completed successfully")
                return True
            
            time.sleep(5)
    
    def check_vm_readiness(self):
        """Check if the GCP VM is ready to handle traffic."""
        if not self.gcp_vm_ip:
            logger.warning("Cannot check VM readiness: IP address not available")
            return
        
        try:
            # Try to connect to the app endpoint
            response = requests.get(f"http://{self.gcp_vm_ip}/metrics", timeout=5)
            
            if response.status_code == 200:
                logger.info("GCP VM is ready to handle traffic!")
                self.migration_complete = True
                self.notify_migration_complete()
        except Exception as e:
            logger.info(f"VM is still starting up: {e}")
    
    def perform_health_checks(self):
        """Perform periodic health checks on the system."""
        # Only run checks if we've already created a VM
        if not self.gcp_vm_created:
            return
        
        # Check if VM still exists
        if not self.check_vm_exists():
            return  # VM doesn't exist, state already reset in check_vm_exists
        
        # If migration is complete, check if VM is still responding
        if self.migration_complete and self.gcp_vm_ip:
            try:
                response = requests.get(f"http://{self.gcp_vm_ip}/metrics", timeout=5)
                if response.status_code != 200:
                    logger.warning(f"VM health check failed: HTTP {response.status_code}")
                    self.health_check_failures += 1
                else:
                    logger.info("VM health check passed")
                    self.health_check_failures = 0  # Reset failures counter
            except Exception as e:
                logger.warning(f"VM health check failed: {e}")
                self.health_check_failures += 1
            
            # If too many health check failures, reset state
            if self.health_check_failures >= self.max_health_check_failures:
                logger.error(f"Too many health check failures ({self.health_check_failures}). Resetting state.")
                self.gcp_vm_created = False
                self.gcp_vm_ip = None
                self.migration_complete = False
                self.health_check_failures = 0
    
    def notify_migration_complete(self):
        """Handle post-migration tasks and notifications."""
        logger.info("=" * 60)
        logger.info("MIGRATION COMPLETE")
        logger.info(f"Application is now running on GCP at http://{self.gcp_vm_ip}")
        logger.info(f"You can access the metrics at http://{self.gcp_vm_ip}/metrics")
        logger.info("=" * 60)
        
        
        # For a real-world scenario, might want to stop or modify the local app
        try:
            subprocess.run(['sudo', 'systemctl', 'stop', 'stress-app'], check=True)
            logger.info("Local application service stopped")
        except Exception as e:
            logger.error(f"Failed to stop local service: {e}")

def main():
    logger.info("Starting Auto-Scaler monitoring service")
    
    scaler = AutoScaler()
    health_check_interval = 60  # seconds
    last_health_check = 0
    
    try:
        while True:
            # Always check resources
            scaler.check_resource_usage()
            
            # Perform health checks at the specified interval
            current_time = time.time()
            if current_time - last_health_check > health_check_interval:
                scaler.perform_health_checks()
                last_health_check = current_time
            
            # After migration is complete, just check in occasionally
            if scaler.migration_complete:
                if time.time() % 60 < CHECK_INTERVAL:  # Log approximately once per minute
                    logger.info("Monitoring mode: Migration to GCP active, VM is healthy")
            
            time.sleep(CHECK_INTERVAL)
    except KeyboardInterrupt:
        logger.info("Auto-Scaler monitoring stopped by user")
    except Exception as e:
        logger.error(f"Auto-Scaler encountered an error: {e}")
        logger.exception("Exception details:")

if __name__ == "__main__":
    main()
