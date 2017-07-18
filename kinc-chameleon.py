import argparse
import datetime
import json
import subprocess
import sys
import time

# default options for command-line arguments
IDENTITY_FILE='chameleon_rsa'
KEY_NAME='chameleon'
LEASE_NAME='kinc-script-lease'
MASTER_IMAGE='kinc-master.v2'
MASTER_INSTANCE_NAME='kinc-master'
NETWORK_NAME='sharednet1'
WORKER_IMAGE='kinc-worker.v2'
WORKER_INSTANCE_PREFIX='kinc-w'

# Run an openstack command and request json output.
# Return the parsed json output of the command.
def json_command(args):
    cmd = list(args) + ['-f', 'json']
    stdout = subprocess.check_output(cmd)
    return json.loads(stdout)

# Get the status of the named lease.
def lease_state(name):
    cmd = ['climate', 'lease-show', name]
    state = json_command(cmd)
    #TODO why can't we recursively decode?
    state['reservations'] = json.loads(state['reservations'])
    return state

# Create a lease for TOTAL_RESERVATION_COUNT compute nodes.
# The lease starts in +2 minutes and will last 1 day.
def create_lease(name):
    reservation = 'min=%(count)s,max=%(count)s,resource_properties=["=", "$node_type", "compute"]' % {'count' : TOTAL_RESERVATION_COUNT}
    date_format = '%Y-%m-%d %H:%M'
    start = datetime.datetime.utcnow() + datetime.timedelta(minutes=2)
    end = start + datetime.timedelta(days=1)
    cmd = ['climate', 'lease-create',
           '--physical-reservation', reservation,
           '--start-date', start.strftime(date_format),
           '--end-date', end.strftime(date_format),
           name]
    try:
        json_command(cmd)
    except ValueError:
        # json decoding is expected to fail because the lease-create
        # command gives bad output
        pass

# Wait for a lease to start.
# Creates the lease if it doesn't exist.
# Sleeps for 30 seconds between checks.
# Returns the lease information.
def ensure_lease(name):
    try:
        state = lease_state(name)
    except:
        # assume the lease doesn't exist yet
        create_lease(name)
        state = lease_state(name)
    
    # wait until the lease has finished starting
    while not (state['action'] == 'START' and state['status'] == 'COMPLETE'):
        #TODO handle other states like 'STOP'
        assert state['status'] == 'IN_PROGRESS' or state['action'] == 'CREATE'
        print 'Waiting for lease to become active.  Lease: ', name, ' , State: ', state['action'],' , Start_date: ', state['start_date']
        time.sleep(30)
        state = lease_state(name)
    
    print 'Lease is ready.  Lease: ', name, ' , State: ', state['action'], ', Start_date: ', state['start_date'] ,', ID: ', state['reservations']['id']
    return state

# Launch a bare metal server instance.
# Return the instance info.
def create_server(name, image, lease_id, user_data=None):
    cmd = ['openstack', 'server', 'create',
           '--flavor', 'baremetal',
           '--image', image,
           '--key-name', KEY_NAME,
           '--network', NETWORK_NAME,
           '--hint', 'reservation='+lease_id,
           name]
    if user_data is not None:
        cmd = cmd + ['--user-data', user_data]
    return json_command(cmd)

# Return the info of a server by its id.
def server_state(server_id):
    cmd = ['openstack', 'server', 'show',
           server_id]
    return json_command(cmd)

# Wait for a server to be assigned an IP address.
# Returns the IP address.
def ensure_ip(server_id):
    ip = None
    while not ip:
        state = server_state(server_id)
        if state['addresses']:
            ip = state['addresses'].split('=')[1]
        else:
            print 'Not Ready... sleeping 30 sec'
            time.sleep(30)
    return ip

# Build a hosts database in memory.
# Combines hosts.base and the names, addresses of the master and workers.
# Returns the lines of the combined hosts database.
def build_hosts(base, master_ip, worker_ips):
    # read the base file containing entries for localhost etc.
    with open(base) as f:
        hosts_base = f.readlines()
    
    # make an entry for the master
    hosts_master = '\t'.join([master_ip, MASTER_INSTANCE_NAME+'.novalocal', MASTER_INSTANCE_NAME]) + '\n'
    
    # make entries for the workers
    hosts_workers = []
    i = 0
    for worker_ip in worker_ips:
        i = i + 1
        host_worker = '\t'.join([worker_ip,
                                 WORKER_INSTANCE_PREFIX+str(i)+'.novalocal',
                                 WORKER_INSTANCE_PREFIX+str(i)]) + '\n'
        hosts_workers.append(host_worker)
    
    return hosts_base + [hosts_master] + hosts_workers

# Assign the first unused floating IP address to a server.
# Returns the IP address that was assigned.
def assign_free_floating_ip(server_id):
    # find an unused floating IP
    #TODO handle the case when there are no free IP addresses
    cmd = ['openstack', 'floating', 'ip', 'list',
           '--network', 'ext-net',
           '--status', 'DOWN']
    res = json_command(cmd)
    ip = res[0]['Floating IP Address']
    
    # assign the IP address
    cmd = ['openstack', 'server', 'add', 'floating', 'ip',
           server_id, ip]
    subprocess.check_call(cmd)
    return ip

# Wait until an SSH server allows logins.
# Sleeps for 10 seconds between attempts.
def wait_for_ssh(ip):
    cmd = ['ssh'] + SSH_OPTS + ['cc@'+ip, '/bin/true']
    ready = (subprocess.call(cmd) == 0)
    while not ready:
        print 'Waiting for the master to accept connections...'
        time.sleep(10)
        ready = (subprocess.call(cmd) == 0)

# Bootstrap the master node.
# Copies the hosts database and master boot script.
# Runs the master boot script giving it the name of each worker.
def configure_master(ip, worker_names):
    cmd = ['scp'] + SSH_OPTS + ['hosts.build', 'master-boot-script.sh', 'cc@'+ip+':']
    subprocess.check_call(cmd)
    cmd = ['ssh'] + SSH_OPTS + ['cc@'+ip, 'sudo', '/bin/bash', '/home/cc/master-boot-script.sh', ' '.join(worker_names)]
    subprocess.check_call(cmd)

# Get a command-line argument parser for this script.
def build_parser():
    # Check for integers >= 0.
    def natural_number(value):
        msg = '"%s" is not a natural number (>= 0)' % value 
        try:
            ival = int(value)
        except:
            raise argparse.ArgumentTypeError(msg)
        if ival < 0:
            raise argparse.ArgumentTypeError(msg)
        return ival
    
    # ArgumentDefaultsHelpFormatter shows default values in the help text
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    
    parser.add_argument('--identity', default=IDENTITY_FILE, help='SSH identity file')
    parser.add_argument('--key', default=KEY_NAME, help='Chameleon key pair')
    parser.add_argument('--lease', default=LEASE_NAME, help='lease name')
    parser.add_argument('--master-image', default=MASTER_IMAGE, help='master image name')
    parser.add_argument('--master-name', default=MASTER_INSTANCE_NAME, help='master instance name')
    parser.add_argument('--network', default=NETWORK_NAME, help='network name')
    parser.add_argument('--worker-image', default=WORKER_IMAGE, help='worker image name')
    parser.add_argument('--worker-prefix', default=WORKER_INSTANCE_PREFIX, help='worker instance prefix')
    parser.add_argument('workers', type=natural_number, help='number of workers to start')
    
    return parser

# Main program
def main(args=None):
    if args is None:
        args = sys.argv[1:]
    
    # parse command-line arguments
    parser = build_parser()
    parsed_args = parser.parse_args(args)
    
    # load options into global vars
    #TODO replace globals with args
    global IDENTITY_FILE, KEY_NAME, LEASE_NAME, MASTER_IMAGE, MASTER_INSTANCE_NAME, NETWORK_NAME, SSH_OPTS, TOTAL_RESERVATION_COUNT, WORKER_IMAGE, WORKER_INSTANCE_PREFIX, WORKER_COUNT
    IDENTITY_FILE = parsed_args.identity
    KEY_NAME = parsed_args.key
    LEASE_NAME = parsed_args.lease
    MASTER_IMAGE = parsed_args.master_image
    MASTER_INSTANCE_NAME = parsed_args.master_name
    NETWORK_NAME = parsed_args.network
    WORKER_IMAGE = parsed_args.worker_image
    WORKER_INSTANCE_PREFIX = parsed_args.worker_prefix
    WORKER_COUNT = parsed_args.workers
    # dependent variables
    SSH_OPTS = SSH_OPTS=['-o', 'StrictHostKeyChecking=no', '-i', IDENTITY_FILE]
    TOTAL_RESERVATION_COUNT = WORKER_COUNT + 1
    
    # start a lease for the master + workers
    leaseinfo = ensure_lease(LEASE_NAME)
    resid = leaseinfo['reservations']['id']
    
    # start the workers
    worker_ids = [create_server(WORKER_INSTANCE_PREFIX+str(i),
                                WORKER_IMAGE,
                                resid,
                                'worker-boot-script.sh')['id']
                   for i in range(1, WORKER_COUNT + 1)]
    
    # start the master
    master_id = create_server(MASTER_INSTANCE_NAME,
                              MASTER_IMAGE,
                              resid)['id']
    
    # get the internal IP addresses of the workers and master
    worker_ips = [ensure_ip(worker_id) for worker_id in worker_ids]
    master_ip = ensure_ip(master_id)
    
    # write a new hosts database file with the internal IP addresses
    with open('hosts.build', 'w') as f:
        f.writelines(build_hosts('hosts.base', master_ip, worker_ips))
    
    # assign an external floating IP address to the master
    floating_ip = assign_free_floating_ip(master_id)
    
    # run the master's bootstrap script
    #TODO re-use the worker names generated earlier
    worker_names = [WORKER_INSTANCE_PREFIX+str(i) for i in range(1, WORKER_COUNT + 1)]
    wait_for_ssh(floating_ip)
    configure_master(floating_ip, worker_names)
    
    print "==============================="
    print "ALL DONE! You may ssh to cc@"+floating_ip+" and start your work."
    print "==============================="
    
if __name__ == '__main__':
    main()
