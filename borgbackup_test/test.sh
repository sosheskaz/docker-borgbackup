#!/bin/bash

STARTDIR="$(realpath "$(dirname "$0")")"
BB_IMAGE_TAG=`uuidgen`
BB_IMAGE_NAME="ericmiller/borgbackup:${BB_IMAGE_TAG}"
TESTUSER_PASSWD=`openssl rand 20 | base64`

cleanup() {
  cd "${STARTDIR}"
  echo "Tearing down docker-compose..."
  docker-compose down || true
  echo "Deleting docker image..."
  docker image rm "${BB_IMAGE_NAME}" || true
}

buildImage() {
  local origdir=`pwd`
  cd "${STARTDIR}/.." || return 1
  docker build -t "${BB_IMAGE_NAME}" . || return 1
  cd "$origdir" || return 1
}

startUp() {
  local origdir=`pwd`
  cd "${STARTDIR}" || return 1
  BORGBACKUP_TAG=$BB_IMAGE_TAG docker-compose up -d || return 1
}

die() {
  echo "Error:" "$@"
  cleanup
  echo "Script failed!"
  exit 1
}

cd "${STARTDIR}" || die "cd into our own directory failed!"

cleanup

echo "Building image..."
buildImage || die "Building the image failed!"

echo "Starting docker-compose..."
startUp || die "Starting docker-compose failed!"

echo "Creating test user..."
docker-compose exec borg_client adduser -u 777 -D -h /home/testuser testuser || die "Failed to create test user on client"
docker-compose exec borg_server adduser -u 777 -D -h /home/testuser testuser || die "Failed to create test user on server"
docker-compose exec borg_server sh -c "echo -n 'testuser:${TESTUSER_PASSWD}' | chpasswd" || die "Failed to set testuser password"
echo "Test user created!"

echo "Generating SSH keys..."
docker-compose exec -u testuser borg_client ssh-keygen -f /home/testuser/.ssh/id_ed25519 -t ed25519 -N '' || die "Failed to generate SSH key"
docker-compose exec -u testuser borg_server sh -c 'mkdir -p -m 700 ~/.ssh' || die "Failed to create .ssh directory"

docker-compose exec borg_server ssh-keygen -A || die "Failed to generate SSHD host keys"

echo "Configuring SSH..."
docker-compose exec borg_server sed 's/^\#?\s*PasswordAuthentication.+$/PasswordAuthentication no/g' -E -i /etc/ssh/sshd_config || die "Failed to disable SSHd Passwordauth"
docker-compose exec borg_server sed 's/^\#?\s*ChallengeResponseAuthentication.+$/ChallengeResponseAuthentication no/g' -E -i /etc/ssh/sshd_config || die "Failed to disable SSHd ChallengeResponse"
docker-compose exec borg_server sed 's/^\#?\s*PermitEmptyPasswords.+$/PermitEmptyPasswords yes/g' -E -i /etc/ssh/sshd_config || die "Failed to enable empty passwords"
AUTHORIZED_KEY=`docker-compose exec -u testuser borg_client sh -c 'cat ~/.ssh/id_ed25519.pub'` || die "Failed to read authorized key"
docker-compose exec -u testuser borg_server sh -c "echo '${AUTHORIZED_KEY}' >> ~/.ssh/authorized_keys" || die "Failed to copy authorized key"
docker-compose exec -u testuser borg_server sh -c 'chmod 600 ~/.ssh/authorized_keys' || die "Failed to chown authorized_keys"
echo "SSH Configured!"

echo "Starting SSH server..."
docker-compose exec borg_server /usr/sbin/sshd || die "Failed to start SSHd"
echo "SSH Server Started!"

echo "Setting up SSH trust..."
docker-compose exec -u testuser borg_client sh -c 'ssh-keyscan -H borg_server >> /home/testuser/.ssh/known_hosts' || die "Failed to import borg_server host keys"
echo "SSH Trusted Host added!"

echo "Testing SSH..."
docker-compose exec -u testuser borg_client ssh borg_server true || die "SSH failed!"
echo "SSH Succeeded!"

echo "Initializing borg repo..."
BORG_PASSWORD=`openssl rand 20 | base64` || die "Failed to generate borg password!"
docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg init -e keyfile borg_server:repo/" || die "Failed to init borg repo!"
for compression in none lz4 zstd lzma zlib auto,lzma
do
  echo "Testing compression: $compression:"
  docker-compose exec -u testuser borg_client sh -c "dd if=/dev/urandom bs=32M count=4 | base64 > ~/${compression}.b64" || die "Failed to generate test files for compression=${compression} backup!"
  docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg create -C '${compression}' -s borg_server:repo::\$(date -Iseconds) ~" || die "Failed to create compression=${compression} backup!"
  sleep 1
done

docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg info borg_server:repo" || die "Failed to fetch repo info!"
docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg list borg_server:repo" || die "Failed to list backups!"
docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg check borg_server:repo" || die "Failed to validate repo integrity!"
docker-compose exec -u testuser borg_client sh -c "BORG_PASSPHRASE='${BORG_PASSWORD}' borg prune --keep-secondly 1 borg_server:repo" || die "Failed to Prune backup!"

cleanup
