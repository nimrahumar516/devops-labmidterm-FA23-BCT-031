#!/bin/bash
# One-time EC2 bootstrap (Ubuntu 24.04): Docker + Java + Jenkins (port 8080).
# Use as EC2 "User data" at launch, or run with: sudo bash ec2-setup.sh
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# 2 GB swap so small instances (t2/t3.micro) survive Docker builds + Jenkins.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get update -y
apt-get install -y docker.io git curl fontconfig openjdk-21-jre-headless
systemctl enable --now docker

# Jenkins (LTS WAR) as a systemd service.
id jenkins >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/jenkins --shell /bin/bash jenkins
usermod -aG docker jenkins
mkdir -p /opt/jenkins
curl -fsSL -o /opt/jenkins/jenkins.war https://get.jenkins.io/war-stable/latest/jenkins.war

cat > /etc/systemd/system/jenkins.service <<'EOF'
[Unit]
Description=Jenkins CI
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=jenkins
Group=jenkins
Environment=JENKINS_HOME=/var/lib/jenkins
ExecStart=/usr/bin/java -Djava.awt.headless=true -Xmx768m -jar /opt/jenkins/jenkins.war --httpPort=8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now jenkins
echo "Jenkins starting on :8080. Initial admin password:"
for i in $(seq 1 60); do
  [ -f /var/lib/jenkins/secrets/initialAdminPassword ] && break
  sleep 3
done
cat /var/lib/jenkins/secrets/initialAdminPassword || true
