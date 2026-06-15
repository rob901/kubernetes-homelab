WSL_IP=$(hostname -I | awk '{print $1}')
powershell.exe -Command "netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$WSL_IP"
powershell.exe -Command "New-NetFirewallRule -Name wsl-ssh -DisplayName 'WSL2 SSH' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 2222"
