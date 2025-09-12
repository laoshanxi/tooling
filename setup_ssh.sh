#!/bin/bash

# Simple Ubuntu SSH setup script

# Check if running as root
if [[ $EUID -ne 0 ]]; then
	echo "Please run this script with sudo"
	exit 1
fi

echo "Setting up SSH remote login..."

# Install SSH server
apt update
apt install -y openssh-server

# Configure SSH to allow root login and password authentication
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Ensure required configurations exist
grep -q "PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >>/etc/ssh/sshd_config
grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >>/etc/ssh/sshd_config

# Start SSH service
systemctl restart ssh
systemctl enable ssh

# Open firewall port
ufw allow 22

echo "SSH setup complete!"
echo "You can now connect to this server via SSH"
echo "Connection command: ssh username@server_ip_address"
