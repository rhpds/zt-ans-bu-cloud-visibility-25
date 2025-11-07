#!/bin/bash

systemctl stop systemd-tmpfiles-setup.service
systemctl disable systemd-tmpfiles-setup.service
systemctl stop firewalld
systemctl disable firewalld

nmcli connection add type ethernet con-name enp2s0 ifname enp2s0 ipv4.addresses 192.168.1.10/24 ipv4.method manual connection.autoconnect yes
nmcli connection up enp2s0
echo "192.168.1.10 control.lab control controller" >> /etc/hosts

echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
chmod 440 /etc/sudoers.d/rhel_sudoers
echo "Checking SSH keys for rhel user..."

RHEL_SSH_DIR="/home/rhel/.ssh"
RHEL_PRIVATE_KEY="$RHEL_SSH_DIR/id_rsa"
RHEL_PUBLIC_KEY="$RHEL_SSH_DIR/id_rsa.pub"

if [ -f "$RHEL_PRIVATE_KEY" ]; then
    echo "SSH key already exists for rhel user: $RHEL_PRIVATE_KEY"
else
    echo "Creating SSH key for rhel user..."
    sudo -u rhel mkdir -p /home/rhel/.ssh
    sudo -u rhel chmod 700 /home/rhel/.ssh
    sudo -u rhel ssh-keygen -t rsa -b 4096 -C "rhel@$(hostname)" -f /home/rhel/.ssh/id_rsa -N "" -q
    sudo -u rhel chmod 600 /home/rhel/.ssh/id_rsa*
    
    if [ -f "$RHEL_PRIVATE_KEY" ]; then
        echo "SSH key created successfully for rhel user"
    else
        echo "Error: Failed to create SSH key for rhel user"
    fi
fi

# # Set proper ownership and permissions
# chown rhel:rhel /home/rhel/aws/config
# chmod 600 /home/rhel/aws/config

# nmcli connection add type ethernet con-name enp2s0 ifname enp2s0 ipv4.addresses 192.168.1.10/24 ipv4.method manual connection.autoconnect yes
# nmcli connection up enp2s0
# echo "192.168.1.10 control.lab control" >> /etc/hosts


# ## set user name
# USER=rhel

# ## setup rhel user
# touch /etc/sudoers.d/rhel_sudoers
# echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
# cp -a /root/.ssh/* /home/$USER/.ssh/.
# chown -R rhel:rhel /home/$USER/.ssh

# ## ansible home
# mkdir /home/$USER/ansible
# ## ansible-files dir
# mkdir /home/$USER/ansible-files

# ## ansible.cfg
# echo "[defaults]" > /home/$USER/.ansible.cfg
# echo "inventory = /home/$USER/ansible-files/hosts" >> /home/$USER/.ansible.cfg
# echo "host_key_checking = False" >> /home/$USER/.ansible.cfg

# ## chown and chmod all files in rhel user home
# chown -R rhel:rhel /home/$USER/ansible
# chmod 777 /home/$USER/ansible
# #touch /home/rhel/ansible-files/hosts
# chown -R rhel:rhel /home/$USER/ansible-files

## install python3 libraries needed for the Cloud Report
dnf install -y python3-pip python3-libsemanage


# Create a playbook for the user to execute
cat <<EOF | tee /tmp/setup.yml
### Automation Controller setup 
###
---
- name: Deploy credentials and AAP resources
  hosts: localhost
  gather_facts: false
  become: true
  vars:
    aws_access_key: "{{ lookup('env', 'AWS_ACCESS_KEY_ID') | default('AWS_ACCESS_KEY_ID_NOT_FOUND', true) }}"
    aws_secret_key: "{{ lookup('env', 'AWS_SECRET_ACCESS_KEY') | default('AWS_SECRET_ACCESS_KEY_NOT_FOUND', true) }}"
    aws_default_region: "{{ lookup('env', 'AWS_DEFAULT_REGION') | default('AWS_DEFAULT_REGION_NOT_FOUND', true) }}"

  tasks:
  
    - name: Add SSH Controller credential to automation controller
      ansible.controller.credential:
        name: SSH Controller Credential
        description: Creds to be able to SSH the contoller_host
        organization: "Default"
        state: present
        credential_type: "Machine"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
        inputs:
          username: rhel
          ssh_key_data: "{{ lookup('file','/home/rhel/.ssh/id_rsa') }}"
      register: controller_try
      retries: 10
      until: controller_try is not failed

    - name: Add AWS credential to automation controller
      ansible.controller.credential:
        name: AWS_Credential
        description: Amazon Web Services
        organization: "Default"
        state: present
        credential_type: "Amazon Web Services"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
        inputs:
          username: "{{ aws_access_key }}"
          password: "{{ aws_secret_key }}"
      register: controller_try
      retries: 10
      until: controller_try is not failed

    - name: Add EE to the controller instance
      ansible.controller.execution_environment:
        name: "AWS Execution Environment"
        image: quay.io/acme_corp/aws_ee
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false

    - name: Add project
      ansible.controller.project:
        name: "AWS Demos Project"
        description: "This is from github.com/ansible-cloud"
        organization: "Default"
        state: present
        scm_type: git
        scm_url: https://github.com/ansible-tmm/awsinfravis25
        default_environment: "Default execution environment"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false

    - name: Delete native job template
      ansible.controller.job_template:
        name: "Demo Job Template"
        state: "absent"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false

    - name: Create job template
      ansible.controller.job_template:
        name: "{{ item.name }}"
        job_type: "run"
        organization: "Default"
        inventory: "Demo Inventory"
        project: "AWS Demos Project"
        playbook: "{{ item.playbook }}"
        credentials:
          - "AWS_Credential"
        state: "present"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
        extra_vars:
          controller_host: "{{ ansible_host }}"
      with_items:
        - { playbook: 'playbooks/aws_resources.yml', name: 'Create AWS Resources' }
        - { playbook: 'playbooks/aws_instances.yml', name: 'Create AWS Instances' }

    - name: Launch a job template
      ansible.controller.job_launch:
        job_template: "Create AWS Resources"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
      register: job

    - name: Wait for job to finish
      ansible.controller.job_wait:
        job_id: "{{ job.id }}"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!    
        validate_certs: false

    - name: Launch a job template
      ansible.controller.job_launch:
        job_template: "Create AWS Instances"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
      register: job2

    - name: Wait for job2 to finish
      ansible.controller.job_wait:
        job_id: "{{ job2.id }}"
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!   
        validate_certs: false

    - name: Add ansible-1 host
      ansible.controller.host:
        name: "ansible-1"
        inventory: "Demo Inventory"
        state: present
        controller_host: "https://localhost"
        controller_username: admin
        controller_password: ansible123!
        validate_certs: false
        variables:
            note: in production these passwords would be encrypted in vault
            ansible_user: rhel
            ansible_password: ansible123!
            ansible_host: controller

EOF

export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

#ANSIBLE_COLLECTIONS_PATH=/tmp/ansible-automation-platform-containerized-setup-bundle-2.5-9-x86_64/collections/:/root/.ansible/collections/ansible_collections/ ansible-playbook -i /tmp/inventory /tmp/setup.yml
