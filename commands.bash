# Update and install required packages

sudo apt update
sudo apt upgrade -y
sudo apt install -y python3-pip python3-venv git wget curl unzip gnupg2 apt-transport-https

# Install Node Exporter for system metrics
# Download and install Node Exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.3.1/node_exporter-1.3.1.linux-amd64.tar.gz
tar xvfz node_exporter-1.3.1.linux-amd64.tar.gz
sudo mv node_exporter-1.3.1.linux-amd64/node_exporter /usr/local/bin/
sudo useradd -rs /bin/false node_exporter

# Create a systemd service for Node Exporter
sudo tee /etc/systemd/system/node_exporter.service > /dev/null << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Start and enable Node Exporter
sudo systemctl daemon-reload
sudo systemctl start node_exporter
sudo systemctl enable node_exporter

# Verify it's running
sudo systemctl status node_exporter

# Install Prometheus
# Download and install Prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.35.0/prometheus-2.35.0.linux-amd64.tar.gz
tar xvfz prometheus-2.35.0.linux-amd64.tar.gz
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo cp prometheus-2.35.0.linux-amd64/prometheus /usr/local/bin/
sudo cp prometheus-2.35.0.linux-amd64/promtool /usr/local/bin/
sudo cp -r prometheus-2.35.0.linux-amd64/consoles /etc/prometheus
sudo cp -r prometheus-2.35.0.linux-amd64/console_libraries /etc/prometheus

# Create prometheus.yml configuration
sudo tee /etc/prometheus/prometheus.yml > /dev/null << EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF

# Create a Prometheus service
sudo tee /etc/systemd/system/prometheus.service > /dev/null << EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

# Start and enable Prometheus
sudo systemctl daemon-reload
sudo systemctl start prometheus
sudo systemctl enable prometheus

# Check status
sudo systemctl status prometheus

# Install Grafana
# Add Grafana APT repository
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# Update and install Grafana
sudo apt update
sudo apt install -y grafana

# Start and enable Grafana
sudo systemctl start grafana-server
sudo systemctl enable grafana-server

# Check status
sudo systemctl status grafana-server

# Set up a Python virtual environment
mkdir -p ~/auto-scale-project
cd ~/auto-scale-project

# Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate

# Install required packages
pip install flask psutil gunicorn requests google-api-python-client google-auth google-auth-httplib2 oauth2client numpy


# Create a Gunicorn service
sudo tee /etc/systemd/system/stress-app.service > /dev/null << EOF
[Unit]
Description=Stress Testing Flask Application
After=network.target

[Service]
User=sunirban
WorkingDirectory=/home/sunirban/auto-scale-project
ExecStart=/home/sunirban/auto-scale-project/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:5000 app:app
Environment="PATH=/home/sunirban/auto-scale-project/venv/bin:/usr/bin:/bin"
Environment="PYTHONPATH=/home/sunirban/auto-scale-project"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl start stress-app
sudo systemctl enable stress-app

# Check status
sudo systemctl status stress-app

# Setting up gcp
# Add the Google Cloud SDK distribution URI as a package source
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# Import the Google Cloud public key
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -

# Update and install the Cloud SDK
sudo apt update && sudo apt install -y google-cloud-cli

# Initialize gcloud
gcloud init
gcloud projects create --name="VCC Auto Scaling Assignment 3"
gcloud config set project YOUR-NEW-PROJECT-ID
gcloud services enable compute.googleapis.com

# Create a service account for auto-scaling
# Create a service account
gcloud iam service-accounts create auto-scaler \
    --display-name="Auto-Scaler Service Account"

# Get your project ID
PROJECT_ID=$(gcloud config get-value project)

# Grant necessary permissions to the service account
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:auto-scaler@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/compute.admin"

# Create and download a key file
gcloud iam service-accounts keys create ~/auto-scale-project/gcp-credentials.json \
    --iam-account=auto-scaler@$PROJECT_ID.iam.gserviceaccount.com
	

# Create a VM image for auto-scaling
mkdir -p ~/auto-scale-project/gcp

chmod +x ~/auto-scale-project/gcp/startup-script.sh


# Implementing the Auto-Scaling Logic
cd ~/auto-scale-project

sudo tee /etc/systemd/system/auto-scaler.service > /dev/null << EOF
[Unit]
Description=Resource Usage Auto-Scaler
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=/home/$(whoami)/auto-scale-project
ExecStart=/home/$(whoami)/auto-scale-project/venv/bin/python auto_scaler.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
chmod +x ~/auto-scale-project/auto_scaler.py
# Start the monitoring services if not already running
sudo systemctl start node_exporter prometheus grafana-server

# Start the stress application
sudo systemctl start stress-app

# Start the auto-scaler
sudo systemctl start auto-scaler
sudo systemctl enable auto-scaler

# Follow the auto-scaler logs in real-time
tail -f ~/auto-scale-project/auto_scaler.log

# Get your project ID
PROJECT_ID=$(gcloud config get-value project)

# Grant the service account user role
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:auto-scaler@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
  

# Grant necessary permissions to the Compute Engine service account
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:978682234295-compute@developer.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1"
	

# Allow HTTP traffic to your VM
gcloud compute firewall-rules create allow-http \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server

# Allow HTTPS traffic
gcloud compute firewall-rules create allow-https \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=https-server
	
# Create a firewall rule to allow SSH
gcloud compute firewall-rules create allow-ssh \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server
	
