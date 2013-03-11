#!/bin/bash
# <UDF name="hostname" label="Hostname">
# <UDF name="domain_name" label="Domain name">
# <UDF name="deployer_username" label="Deployer username">
# <UDF name="deployer_password" label="Deployer password">
# <UDF name="ssh_port" label="SSH port">
# <UDF name="ruby_version" label="Ruby version">
# <UDF name="app_name" label="App name">


# Install packages
echo "Installing packages..."
apt-get -y update
apt-get -y upgrade

apt-get -y install build-essential curl python-software-properties openssl lsof

add-apt-repository ppa:nginx/stable
apt-get -y update
apt-get -y install nginx
sed 's/default_server;/ipv6only=on default_server;/g' /etc/nginx/sites-available/default > /etc/nginx/sites-available/default_temp
mv /etc/nginx/sites-available/default_temp /etc/nginx/sites-available/default
service nginx start

add-apt-repository ppa:pitti/postgresql
apt-get -y update
apt-get -y install postgresql libpq-dev

add-apt-repository ppa:chris-lea/node.js
apt-get -y update
apt-get -y install nodejs

add-apt-repository ppa:voronov84/andreyv
apt-get -y update
apt-get -y install git


# Set hostname
echo "Setting hostname..."
echo "$HOSTNAME" > /etc/hostname
hostname -F /etc/hostname
if [ -d "/etc/default/dhcpcd" ]; then
  sed 's/SET_HOSTNAME/#SET_HOSTNAME/g' /etc/default/dhcpcd > /etc/default/dhcpcd_temp
  mv /etc/default/dhcpcd_temp /etc/default/dhcpcd
fi

IP_ADDRESS=`ifconfig | grep 'inet addr:' | grep -v '127.0.0.1' | cut -d ":" -f2 | awk '{print $1}'`
sed "/127\.0\.0\.1/ a\
$IP_ADDRESS  $HOSTNAME.$DOMAIN_NAME  $HOSTNAME" /etc/hosts > /etc/hosts_temp
mv /etc/hosts_temp /etc/hosts


# Set time zone to UTC
echo "Setting time zone to UTC..."
cp /usr/share/zoneinfo/UTC /etc/localtime


# Set SSH port and disable SSH root access
echo "Setting SSH port and disabling SSH root access..."
sed "s/Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config > /etc/ssh/sshd_config_temp
mv /etc/ssh/sshd_config_temp /etc/ssh/sshd_config
sed "s/PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config > /etc/ssh/sshd_config_temp
mv /etc/ssh/sshd_config_temp /etc/ssh/sshd_config


# Create user
echo "Creating user '$DEPLOYER_USERNAME'..."
useradd -g admin -m $DEPLOYER_USERNAME
echo $DEPLOYER_USERNAME:$DEPLOYER_PASSWORD | chpasswd
usermod -s /bin/bash $DEPLOYER_USERNAME

DEPLOYER_HOME=/home/$DEPLOYER_USERNAME


# Create script for deployer to restart nginx
echo "Creating nginx restart script..."
echo "#!/bin/bash
service nginx restart" > $DEPLOYER_HOME/restart_nginx
chmod +x $DEPLOYER_HOME/restart_nginx
echo "$DEPLOYER_USERNAME ALL=NOPASSWD:$DEPLOYER_HOME/restart_nginx" >> /etc/sudoers


# Create directories for Rails app and git repository
echo "Creating app directory..."
mkdir $DEPLOYER_HOME/apps
echo "Creating git repository '$APP_NAME.git'..."
mkdir $DEPLOYER_HOME/$APP_NAME.git
cd $DEPLOYER_HOME/$APP_NAME.git
git init --bare --shared
cd


# Update postgres pg_hba.conf for app
echo "Updating PostgreSQL pg_hba.conf..."
PRODUCTION_DB_POSTFIX=_production
POSTGRES_DATABASE=$APP_NAME$PRODUCTION_DB_POSTFIX
PG_HBA=`echo /etc/postgresql/*/*/pg_hba.conf | cut -d " " -f1`
sed "/local.*postgres/ a\
local   $POSTGRES_DATABASE   $APP_NAME      password" $PG_HBA > $PG_HBA.temp
mv $PG_HBA.temp $PG_HBA


# Create postgres user and database for app
echo "Creating PostgreSQL user for app..."
POSTGRES_APP_PASSWORD=`openssl rand -base64 24`
sudo -u postgres psql -c "CREATE USER $APP_NAME WITH PASSWORD '$POSTGRES_APP_PASSWORD';"
echo "Creating PostgreSQL database for app..."
sudo -u postgres psql -c "CREATE DATABASE $POSTGRES_DATABASE OWNER $APP_NAME;"
POSTGRES_PASSWORD_FILE=$DEPLOYER_HOME/apps/$APP_NAME.passwd
echo "$POSTGRES_APP_PASSWORD" > $POSTGRES_PASSWORD_FILE


# Create git post-receive script
echo "Creating post-receive script for '$APP_NAME.git' repository..."
echo -e "#!/usr/bin/env bash
set -e

unset \$(git rev-parse --local-env-vars)
cd $DEPLOYER_HOME/apps

if [ -d \"$DEPLOYER_HOME/apps/$APP_NAME\" ]; then
  # App exists, just pull latest
  echo \"App $APP_NAME found\"
  cd $APP_NAME
  git pull origin master
else
  # App doesn't exist, set it up
  echo \"App $APP_NAME not found\"
  git clone $DEPLOYER_HOME/$APP_NAME.git

  cd $APP_NAME

  # Create tmp/pids directory for Unicorn
  mkdir tmp
  mkdir tmp/pids

  # Create database.yml for production use
  if [ -r \"$POSTGRES_PASSWORD_FILE\" ]; then
    POSTGRES_APP_PASSWORD=\`cat $POSTGRES_PASSWORD_FILE\`
  else
    POSTGRES_APP_PASSWORD=\"\"
  fi

  echo \"production:
  adapter: postgresql
  encoding: unicode
  database: $POSTGRES_DATABASE
  pool: 5
  username: $APP_NAME
  password: \$POSTGRES_APP_PASSWORD\" > config/database.yml

  sudo $DEPLOYER_HOME/restart_nginx
fi

source $DEPLOYER_HOME/.rvm/environments/ruby-$RUBY_VERSION@$APP_NAME

cd $DEPLOYER_HOME/apps/$APP_NAME
echo \"Running bundle install...\"
bundle install

echo \"Running rake assets:precompile...\"
rm -rf public/assets
RAILS_ENV=production rake assets:precompile

echo \"Running rake db:migrate...\"
RAILS_ENV=production rake db:migrate

if [ -e \"/tmp/unicorn.$APP_NAME.sock\" ]; then
  PID=\`lsof -t /tmp/unicorn.$APP_NAME.sock | head -1\`
  if [ -n \"\$PID\" ]; then
    UNICORN_COMMAND=restart
  else
    UNICORN_COMMAND=start
  fi
else
  UNICORN_COMMAND=start
fi
/etc/init.d/unicorn_$APP_NAME \$UNICORN_COMMAND" > $DEPLOYER_HOME/$APP_NAME.git/hooks/post-receive


# Create symlinks to run nginx and unicorn
echo "Creating symlinks for nginx and unicorn usage in app..."
rm /etc/nginx/sites-enabled/default
ln -nfs $DEPLOYER_HOME/apps/$APP_NAME/config/nginx.conf /etc/nginx/sites-enabled/$APP_NAME
ln -nfs $DEPLOYER_HOME/apps/$APP_NAME/config/unicorn_init.sh /etc/init.d/unicorn_$APP_NAME

chmod -R 777 $DEPLOYER_HOME/$APP_NAME.git
chown -R $DEPLOYER_USERNAME:admin $DEPLOYER_HOME/


# Set up RVM for depoyer
echo "Setting up RVM for '$DEPLOYER_USERNAME'..."
su $DEPLOYER_USERNAME -c "cd && curl -#L https://get.rvm.io | bash -s stable && source ~/.rvm/scripts/rvm && rvm install $RUBY_VERSION && rvm gemset create $APP_NAME && rvm gemset use $APP_NAME"


# Show success message and restart
echo
echo "Done!"
echo
echo "Restarting in 10 seconds..."

$(shutdown -r +1) &
