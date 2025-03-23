#!/bin/bash

# Redirect all output to a log file
exec > >(tee /var/log/startup-script.log) 2>&1

echo "Starting setup at $(date)"

# Update and install dependencies
apt-get update
apt-get install -y python3-pip python3-venv git nginx

# Remove default Nginx page
rm -f /var/www/html/index.nginx-debian.html
rm -f /etc/nginx/sites-enabled/default

# Create app directory
mkdir -p /app/templates
cd /app

# Create the HTML file
cat > /app/templates/index.html << 'EOL'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Resource Stress Testing Tool</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0-alpha1/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body {
            padding-top: 20px;
        }
        .gauge-container {
            width: 200px;
            height: 200px;
            margin: 0 auto;
            position: relative;
        }
        .gauge {
            width: 100%;
            height: 100%;
        }
        .gauge-value {
            position: absolute;
            bottom: 0;
            width: 100%;
            text-align: center;
            font-size: 24px;
            font-weight: bold;
        }
        .card {
            margin-bottom: 20px;
        }
        .threshold-line {
            position: absolute;
            left: 0;
            width: 100%;
            height: 2px;
            background-color: red;
            z-index: 1;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1 class="text-center mb-4">Resource Stress Testing Tool</h1>
        
        <div class="row">
            <div class="col-md-6">
                <div class="card">
                    <div class="card-header">
                        CPU Usage
                    </div>
                    <div class="card-body">
                        <div class="gauge-container">
                            <canvas id="cpuGauge" class="gauge"></canvas>
                            <div class="gauge-value" id="cpuValue">0%</div>
                            <div class="threshold-line" style="bottom: 75%;"></div>
                        </div>
                        <div class="mt-3">
                            <h5>CPU Stress Test</h5>
                            <div class="mb-3">
                                <label for="cpuCores" class="form-label">Number of Cores</label>
                                <input type="number" class="form-control" id="cpuCores" value="1" min="1">
                            </div>
                            <div class="mb-3">
                                <label for="cpuDuration" class="form-label">Duration (seconds)</label>
                                <input type="number" class="form-control" id="cpuDuration" value="60" min="1">
                            </div>
                            <button id="startCpuStress" class="btn btn-primary">Start CPU Stress</button>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="col-md-6">
                <div class="card">
                    <div class="card-header">
                        Memory Usage
                    </div>
                    <div class="card-body">
                        <div class="gauge-container">
                            <canvas id="memoryGauge" class="gauge"></canvas>
                            <div class="gauge-value" id="memoryValue">0%</div>
                            <div class="threshold-line" style="bottom: 75%;"></div>
                        </div>
                        <div class="mt-3">
                            <h5>Memory Stress Test</h5>
                            <div class="mb-3">
                                <label for="memorySize" class="form-label">Memory Size (MB)</label>
                                <input type="number" class="form-control" id="memorySize" value="100" min="1">
                            </div>
                            <div class="mb-3">
                                <label for="memoryDuration" class="form-label">Duration (seconds)</label>
                                <input type="number" class="form-control" id="memoryDuration" value="60" min="1">
                            </div>
                            <button id="startMemoryStress" class="btn btn-primary">Start Memory Stress</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="row mt-3">
            <div class="col-12 text-center">
                <button id="stopAllStress" class="btn btn-danger btn-lg">Stop All Stress Tests</button>
            </div>
        </div>
        
        <div class="row mt-4">
            <div class="col-12">
                <div class="card">
                    <div class="card-header">
                        Auto-Scaling Status
                    </div>
                    <div class="card-body">
                        <div id="statusMessages" class="alert alert-info">
                            System is running normally. Resource usage is below threshold.
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0-alpha1/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    
    <script>
        // Initialize gauges
        const cpuGauge = new Chart(document.getElementById('cpuGauge'), {
            type: 'doughnut',
            data: {
                datasets: [{
                    data: [0, 100],
                    backgroundColor: ['#ff6384', '#eeeeee']
                }]
            },
            options: {
                cutout: '70%',
                circumference: 180,
                rotation: 270,
                animation: { duration: 500 },
                plugins: { tooltip: { enabled: false } }
            }
        });
        
        const memoryGauge = new Chart(document.getElementById('memoryGauge'), {
            type: 'doughnut',
            data: {
                datasets: [{
                    data: [0, 100],
                    backgroundColor: ['#36a2eb', '#eeeeee']
                }]
            },
            options: {
                cutout: '70%',
                circumference: 180,
                rotation: 270,
                animation: { duration: 500 },
                plugins: { tooltip: { enabled: false } }
            }
        });
        
        // Update gauges with real data
        function updateMetrics() {
            fetch('/api/metrics')
                .then(response => response.json())
                .then(data => {
                    // Update CPU gauge
                    cpuGauge.data.datasets[0].data = [data.cpu_percent, 100 - data.cpu_percent];
                    cpuGauge.update();
                    document.getElementById('cpuValue').textContent = `${Math.round(data.cpu_percent)}%`;
                    
                    // Update Memory gauge
                    memoryGauge.data.datasets[0].data = [data.memory_percent, 100 - data.memory_percent];
                    memoryGauge.update();
                    document.getElementById('memoryValue').textContent = `${Math.round(data.memory_percent)}%`;
                    
                    // Update status messages
                    if (data.cpu_percent > 75 || data.memory_percent > 75) {
                        document.getElementById('statusMessages').className = 'alert alert-danger';
                        document.getElementById('statusMessages').textContent = 
                            'Resource usage exceeds 75% threshold! Auto-scaling process will be triggered.';
                    } else {
                        document.getElementById('statusMessages').className = 'alert alert-info';
                        document.getElementById('statusMessages').textContent = 
                            'System is running normally. Resource usage is below threshold.';
                    }
                })
                .catch(error => console.error('Error fetching metrics:', error));
        }
        
        // Start periodic updates
        setInterval(updateMetrics, 1000);
        
        // Set up event listeners for buttons
        document.getElementById('startCpuStress').addEventListener('click', function() {
            const cores = parseInt(document.getElementById('cpuCores').value);
            const duration = parseInt(document.getElementById('cpuDuration').value);
            
            fetch('/api/stress/cpu', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cores, duration })
            });
        });
        
        document.getElementById('startMemoryStress').addEventListener('click', function() {
            const size_mb = parseInt(document.getElementById('memorySize').value);
            const duration = parseInt(document.getElementById('memoryDuration').value);
            
            fetch('/api/stress/memory', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ size_mb, duration })
            });
        });
        
        document.getElementById('stopAllStress').addEventListener('click', function() {
            fetch('/api/stress/stop', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({})
            });
        });
    </script>
</body>
</html>
EOL

# Create the app.py file
cat > /app/app.py << 'EOL'
from flask import Flask, render_template, request, jsonify
import psutil
import multiprocessing
import numpy as np
import time
import threading
import os
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

# Global variables to control stress tests
cpu_stress_active = False
memory_stress_active = False
allocated_memory = []

# Function to consume CPU
def consume_cpu(duration=60):
    end_time = time.time() + duration
    while time.time() < end_time and cpu_stress_active:
        # Perform CPU-intensive calculations
        [i**2 for i in range(10000)]
        np.random.random((1000, 1000)).dot(np.random.random((1000, 1000)))
        time.sleep(0.01)  # Small pause to prevent complete system freeze

# Function to consume memory
def consume_memory(size_mb=100, duration=60):
    global allocated_memory
    try:
        # Allocate memory in chunks of 10MB
        chunk_size = 10
        for _ in range(int(size_mb / chunk_size)):
            if not memory_stress_active:
                break
            # Allocate memory and keep a reference to prevent garbage collection
            allocated_memory.append(' ' * (chunk_size * 1024 * 1024))
            time.sleep(0.1)
        
        # Keep the memory allocated for the specified duration
        end_time = time.time() + duration
        while time.time() < end_time and memory_stress_active:
            time.sleep(1)
    finally:
        # Release memory
        allocated_memory = []

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/metrics')
def get_metrics():
    cpu_percent = psutil.cpu_percent()
    memory_percent = psutil.virtual_memory().percent
    
    return jsonify({
        'cpu_percent': cpu_percent,
        'memory_percent': memory_percent,
        'cpu_stress_active': cpu_stress_active,
        'memory_stress_active': memory_stress_active
    })

@app.route('/api/stress/cpu', methods=['POST'])
def stress_cpu():
    global cpu_stress_active
    
    data = request.get_json()
    duration = data.get('duration', 60)
    cores = data.get('cores', 1)
    
    # Stop any existing CPU stress test
    cpu_stress_active = False
    time.sleep(1)  # Give time for existing threads to stop
    
    # Start new stress test
    cpu_stress_active = True
    
    # Start CPU stress test in multiple processes
    for _ in range(min(cores, multiprocessing.cpu_count())):
        threading.Thread(target=consume_cpu, args=(duration,), daemon=True).start()
    
    return jsonify({'status': 'CPU stress test started', 'duration': duration, 'cores': cores})

@app.route('/api/stress/memory', methods=['POST'])
def stress_memory():
    global memory_stress_active, allocated_memory
    
    data = request.get_json()
    size_mb = data.get('size_mb', 100)
    duration = data.get('duration', 60)
    
    # Stop any existing memory stress test
    memory_stress_active = False
    allocated_memory = []
    time.sleep(1)  # Give time for existing memory to be released
    
    # Start new stress test
    memory_stress_active = True
    threading.Thread(target=consume_memory, args=(size_mb, duration), daemon=True).start()
    
    return jsonify({'status': 'Memory stress test started', 'size_mb': size_mb, 'duration': duration})

@app.route('/api/stress/stop', methods=['POST'])
def stop_stress():
    global cpu_stress_active, memory_stress_active, allocated_memory
    
    cpu_stress_active = False
    memory_stress_active = False
    allocated_memory = []
    
    return jsonify({'status': 'All stress tests stopped'})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
EOL

# Set up Python environment
python3 -m venv venv
venv/bin/pip install flask gunicorn psutil numpy

# Configure Nginx - Make sure to set up a default server
cat > /etc/nginx/sites-available/flask-app << 'EOL'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOL

ln -sf /etc/nginx/sites-available/flask-app /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create a systemd service for the Flask app
cat > /etc/systemd/system/flask-app.service << 'EOL'
[Unit]
Description=Gunicorn instance to serve Flask application
After=network.target

[Service]
User=root
WorkingDirectory=/app
ExecStart=/app/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Start and enable services
systemctl daemon-reload
systemctl start flask-app
systemctl enable flask-app
systemctl restart nginx

# Test if the app is working
echo "Testing if the app is running..."
curl -s http://localhost:5000 | grep -q "Resource Stress Testing Tool"
if [ $? -eq 0 ]; then
    echo "Flask app is running correctly!"
else
    echo "Error: Flask app is not running correctly."
    systemctl status flask-app
fi

# Signal that setup is complete
touch /tmp/startup-complete
echo "Setup completed at $(date)"