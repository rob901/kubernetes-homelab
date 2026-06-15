sudo apt-get update && sudo apt-get install -y openssh-server

sudo tee /etc/ssh/sshd_config.d/wsl.conf > /dev/null <<'EOF'
Port 2222
PasswordAuthentication yes
EOF

sudo service ssh start
