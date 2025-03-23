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
