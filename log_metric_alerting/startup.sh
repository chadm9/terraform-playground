curl -sSO https://dl.google.com/cloudagents/add-logging-agent-repo.sh
bash ./add-logging-agent-repo.sh
sudo -E apt-get -y install google-fluentd
sudo apt-get update
sudo -E apt-get -y install google-fluentd
mkdir -p /etc/google-fluentd/config.d

cat > /etc/google-fluentd/config.d/syslog.conf <<EOF
<source>
  @type tail

  # Parse the timestamp, but still collect the entire line as 'message'
  format /^(?<message>(?<time>[^ ]*\s*[^ ]* [^ ]*) .*)$/

  path /var/log/syslog,/var/log/messages
  pos_file /var/lib/google-fluentd/pos/syslog.pos
  read_from_head true
  tag syslog
</source>
EOF

systemctl restart google-fluentd
