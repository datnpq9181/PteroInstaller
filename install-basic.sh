#!/bin/bash

set -e

# Pterodactyl Installer 
# Copyright Forestracks 2022

# exit with error status code if user is not root
if [[ $EUID -ne 0 ]]; then
  echo "* This script must be executed with root privileges (sudo)." 1>&2
  exit 1
fi

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

# define version using information from GitHub
get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
  grep '"tag_name":' |                                              # Get tag line
  sed -E 's/.*"([^"]+)".*/\1/'                                      # Pluck JSON value
}

echo "* Retrieving release information.."
PTERODACTYL_VERSION="$(get_latest_release "pterodactyl/panel")"
echo "* Latest version is $PTERODACTYL_VERSION"

# Generate password
PASSWORD=$(openssl rand -base64 12)

# variables
WEBSERVER="nginx"
FQDN="$(hostname -I | awk '{print $1}')"

# default MySQL credentials
MYSQL_DB="panel"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD="$PASSWORD"

# environment
email="example@forestracks.com"

# Initial admin account
user_email="example@forestracks.com"
user_username="admin"
user_firstname="Cool"
user_lastname="Admin"
user_password="$PASSWORD"

# download URLs
PANEL_DL_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
DL_URL="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
CONFIGS_URL="https://raw.githubusercontent.com/ForestRacks/PteroInstaller/master/configs"

# apt sources path
SOURCES_PATH="/etc/apt/sources.list"

# ufw firewall
CONFIGURE_UFW=false

# firewall_cmd
CONFIGURE_FIREWALL_CMD=false

# firewall status
CONFIGURE_FIREWALL=false

# visual functions
function print_error {
  COLOR_RED='\033[0;31m'
  COLOR_NC='\033[0m'

  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
  echo ""
}

function print_warning {
  COLOR_YELLOW='\033[1;33m'
  COLOR_NC='\033[0m'
  echo ""
  echo -e "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

function print_brake {
  for ((n=0;n<$1;n++));
    do
      echo -n "#"
    done
    echo ""
}

hyperlink() {
  echo -e "\e]8;;${1}\a${1}\e]8;;\a"
}

# other functions
function detect_distro {
  if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$(echo "$ID" | awk '{print tolower($0)}')
    OS_VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si | awk '{print tolower($0)}')
    OS_VER=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$(echo "$DISTRIB_ID" | awk '{print tolower($0)}')
    OS_VER=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS="debian"
    OS_VER=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    OS="SuSE"
    OS_VER="?"
  elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS="Red Hat/CentOS"
    OS_VER="?"
  else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    OS_VER=$(uname -r)
  fi

  OS=$(echo "$OS" | awk '{print tolower($0)}')
  OS_VER_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
}

function check_os_comp {
  if [ "$OS" == "ubuntu" ]; then
    PHP_SOCKET="/run/php/php8.1-fpm.sock"
    CONFIGURE_UFW=true
    if [ "$OS_VER_MAJOR" == "18" ] || [ "$OS_VER_MAJOR" == "20" ] || [ "$OS_VER_MAJOR" == "22" ] || [ "$OS_VER_MAJOR" == "23" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  elif [ "$OS" == "debian" ]; then
    PHP_SOCKET="/run/php/php8.1-fpm.sock"
    CONFIGURE_UFW=true
    if [ "$OS_VER_MAJOR" == "9" ] || [ "$OS_VER_MAJOR" == "10" ] || [ "$OS_VER_MAJOR" == "11" ] || [ "$OS_VER_MAJOR" == "12" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  elif [ "$OS" == "centos" ]; then
    PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
    CONFIGURE_FIREWALL=true
    if [ "$OS_VER_MAJOR" == "7" ]; then
      SUPPORTED=true
    elif [ "$OS_VER_MAJOR" == "8" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  elif [ "$OS" == "almalinux" ]; then
    PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
    CONFIGURE_FIREWALL=true
    if [ "$OS_VER_MAJOR" == "8" ]; then
      SUPPORTED=true
    elif [ "$OS_VER_MAJOR" == "9" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  else
    SUPPORTED=false
  fi

  # exit if not supported
  if [ "$SUPPORTED" == true ]; then
    echo "* $OS $OS_VER is supported."
  else
    echo "* $OS $OS_VER is not supported"
    print_error "Unsupported OS"
    exit 1
  fi
}

#################################
## main installation functions ##
#################################

function install_composer {
  echo "* Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  echo "* Composer installed!"
}

function panel_ptdl_dl {
  echo "* Downloading pterodactyl panel files .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env
  composer install --no-dev --optimize-autoloader --quiet --no-interaction

  php artisan key:generate --force

  # Replace the egg docker images with ForestRacks's optimized images
  for file in /var/www/pterodactyl/database/Seeders/eggs/*/*.json; do
    # Extract the docker_images field from the file using jq
    docker_images=$(jq -r '.docker_images' "$file")

    # Check if the replacement match exists in the docker_images field
    if echo "$docker_images" | grep -q "ghcr.io/pterodactyl/yolks:java_" || echo "$docker_images" | grep -q "quay.io/pterodactyl/core:rust" || echo "$docker_images" | grep -q "quay.io/pterodactyl/games:source" || echo "$docker_images" | grep -q "ghcr.io/pterodactyl/games:source" || echo "$docker_images" | grep -q "quay.io/parkervcp/pterodactyl-images:debian_source"; then
      # Read the contents of the file into a variable
      contents=$(<"$file")

      # Update the docker_images object using multiple jq filters
      contents=$(echo "$contents" | jq '.docker_images |= map_values(. | gsub("ghcr.io/pterodactyl/yolks:java_"; "ghcr.io/forestracks/java:"))' | jq '.docker_images |= map_values(. | gsub("quay.io/pterodactyl/core:rust"; "ghcr.io/forestracks/games:rust"))' | jq '.docker_images |= map_values(. | gsub("quay.io/pterodactyl/games:source"; "ghcr.io/forestracks/games:steam"))' | jq '.docker_images |= map_values(. | gsub("ghcr.io/pterodactyl/games:source"; "ghcr.io/forestracks/games:steam"))' | jq '.docker_images |= map_values(. | gsub("quay.io/parkervcp/pterodactyl-images:debian_source"; "ghcr.io/forestracks/base:main"))')

      # Replace the forward slashes in the docker_images object using sed
      contents=$(echo "$contents" | sed 's/\//\\\//g')
    
      # Write the modified contents back to the file
      echo "$contents" > "$file"
    fi
  done

  echo "* Downloaded pterodactyl panel files & installed composer dependencies!"
}

function configure {
  app_url=http://$FQDN

  # Fill in environment:setup automatically
  php artisan p:environment:setup \
    --telemetry=false \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui="yes"

  # Fill in environment:database credentials automatically
  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  # configures database
  php artisan migrate --seed --force

  # Create user account
  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  # Create a server location
  php artisan p:location:make \
    --short=Main \
    --long="Primary location"

  # Create a node
  php artisan p:node:make \
    --name="Node01" \
    --description="First Node" \
    --fqdn=$FQDN \
    --public=1 \
    --locationId=1 \
    --scheme="http" \
    --proxy="no" \
    --maintenance=0 \
    --maxMemory="$(free -m | awk 'FNR == 2 {print $2}')" \
    --overallocateMemory=0 \
    --maxDisk="$(df --total -m | tail -n 1 | awk '{print $2}')" \
    --overallocateDisk=0 \
    --uploadSize=100 \
    --daemonListeningPort=8080 \
    --daemonSFTPPort=2022 \
    --daemonBase="/var/lib/pterodactyl/volumes"

  # Fetch wings configuration
  mkdir -p /etc/pterodactyl
  echo "$(php artisan p:node:configuration 1)" > /etc/pterodactyl/config.yml

  # set folder permissions now
  set_folder_permissions
}

# set the correct folder permissions depending on OS and webserver
function set_folder_permissions {
  # if os is ubuntu or debian, we do this
  if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
    chown -R www-data:www-data ./*
  elif [ "$OS" == "centos" ] && [ "$WEBSERVER" == "nginx" ] || [ "$OS" == "almalinux" ] && [ "$WEBSERVER" == "nginx" ]; then
    chown -R nginx:nginx ./*
  else
    print_error "Invalid webserver and OS setup."
    exit 1
  fi
}

# insert cronjob
function insert_cronjob {
  echo "* Installing cronjob.. "

  crontab -l | { cat; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"; } | crontab -

  echo "* Cronjob installed!"
}

function ptdl_dl {
  echo "* Installing Pterodactyl Wings .. "

  mkdir -p /etc/pterodactyl
  curl -L -o /usr/local/bin/wings "$DL_URL"

  chmod u+x /usr/local/bin/wings

  echo "* Done."
}

function install_pteroq {
  echo "* Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service $CONFIGS_URL/pteroq.service
  systemctl enable pteroq.service
  systemctl start pteroq

  echo "* Installed pteroq!"
}

function install_docker {
  echo "* Installing docker .."
  if [ "$OS" == "debian" ]; then
    # install dependencies for Docker
    DEBIAN_FRONTEND=noninteractive apt update -y 
    DEBIAN_FRONTEND=noninteractive apt -y install \
     apt-transport-https \
     ca-certificates \
     curl \
     gnupg2 \
     software-properties-common

    # get their GPG key
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -

    # show fingerprint to user
    apt-key fingerprint 0EBFCD88

    # add APT repo
    apt-add-repository -y \
      "deb [arch=amd64] https://download.docker.com/linux/debian \
      $(lsb_release -cs) \
      stable"

    # install docker
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt -y install docker-ce docker-ce-cli containerd.io

    # make sure it's enabled & running
    systemctl start docker
    systemctl enable docker

  elif [ "$OS" == "ubuntu" ]; then
    # install dependencies for Docker
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt -y install \
      apt-transport-https \
      ca-certificates \
      curl \
      software-properties-common

    # get their GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

    # show fingerprint to user
    apt-key fingerprint 0EBFCD88

    # add APT repo
    sudo apt-add-repository -y \
      "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) \
      stable"

    # install docker
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt -y install docker-ce docker-ce-cli containerd.io

    # make sure it's enabled & running
    systemctl start docker
    systemctl enable docker

  elif [ "$OS" == "centos" ]; then
    if [ "$OS_VER_MAJOR" == "7" ]; then
      # install dependencies for Docker
      yum install -y yum-utils device-mapper-persistent-data lvm2

      # add repo to yum
      yum-config-manager \
        --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo

      # install Docker
      yum install -y docker-ce docker-ce-cli containerd.io
    elif [ "$OS_VER_MAJOR" == "8" ]; then
      # install dependencies for Docker
      dnf install -y dnf-utils device-mapper-persistent-data lvm2

      # add repo to dnf
      dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo

      # install Docker
      dnf install -y docker-ce docker-ce-cli containerd.io --nobest
    fi

    # make sure it's enabled & running
    systemctl start docker
    systemctl enable docker

  elif [ "$OS" == "almalinux" ]; then
    if [ "$OS_VER_MAJOR" == "9" ] || [ "$OS_VER_MAJOR" == "9" ]; then
      # install dependencies for Docker
      dnf install -y dnf-utils device-mapper-persistent-data lvm2

      # add repo to dnf
      dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo

      # install Docker
      dnf install -y docker-ce docker-ce-cli containerd.io --nobest
    fi

    # make sure it's enabled & running
    systemctl start docker
    systemctl enable docker
  fi

  echo "* Docker has now been installed."
}

function systemd_file {
  echo "* Installing systemd service.."
  curl -o /etc/systemd/system/wings.service $CONFIGS_URL/wings.service
  systemctl daemon-reload
  systemctl enable wings
  systemctl restart wings
  echo "* Installed systemd service!"
}

function create_database {
  if [ "$OS" == "centos" || "$OS" == "almalinux" ]; then
    # secure MariaDB
    echo "* MariaDB secure installation. The following are safe defaults."
    echo "* Set root password? [Y/n] Y"
    echo "* Remove anonymous users? [Y/n] Y"
    echo "* Disallow root login remotely? [Y/n] Y"
    echo "* Remove test database and access to it? [Y/n] Y"
    echo "* Reload privilege tables now? [Y/n] Y"
    echo "*"

    mysql_secure_installation

    echo "* The script should have asked you to set the MySQL root password earlier (not to be confused with the pterodactyl database user password)"
    echo "* MySQL will now ask you to enter the password before each command."

    echo "* Create MySQL user."
    mysql -u root -p -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

    echo "* Create database."
    mysql -u root -p -e "CREATE DATABASE ${MYSQL_DB};"

    echo "* Grant privileges."
    mysql -u root -p -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"

    echo "* Flush privileges."
    mysql -u root -p -e "FLUSH PRIVILEGES;"
  else
    echo "* Performing MySQL queries.."

    echo "* Creating MySQL user.."
    mysql -u root -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

    echo "* Creating database.."
    mysql -u root -e "CREATE DATABASE ${MYSQL_DB};"

    echo "* Granting privileges.."
    mysql -u root -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"

    echo "* Flushing privileges.."
    mysql -u root -e "FLUSH PRIVILEGES;"

    echo "* MySQL database created & configured!"
  fi
}

##################################
# OS specific install functions ##
##################################

function apt_update {
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
}

function ubuntu_dep {
  echo "* Installing dependencies for Ubuntu 22.."

  # Add "apt-add-repository" command
  DEBIAN_FRONTEND=noninteractive apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg jq
  
  # Add additional repositories for PHP, Redis, and MariaDB
  LC_ALL=C.UTF-8 apt-add-repository -y ppa:ondrej/php
  curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update repositories list
  DEBIAN_FRONTEND=noninteractive apt update -y

  # Add universe repository if you are on Ubuntu 18.04
  apt-add-repository universe -y

  # Install Dependencies
  DEBIAN_FRONTEND=noninteractive apt -y install php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server redis

  # enable services
  systemctl start mariadb
  systemctl enable mariadb
  systemctl start redis-server
  systemctl enable redis-server

  echo "* Dependencies for Ubuntu installed!"
}

function debian_stretch_dep {
  echo "* Installing dependencies for Debian 8/9.."

  # MariaDB need dirmngr
  DEBIAN_FRONTEND=noninteractive apt -y install dirmngr jq

  # install PHP 8.1 using sury's repo instead of PPA
  DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates apt-transport-https lsb-release
  wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list

  # Add the MariaDB repo (oldstable has mariadb version 10.1 and we need newer than that)
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash

  # Update repositories list
  DEBIAN_FRONTEND=noninteractive apt update -y

  # Install Dependencies
  DEBIAN_FRONTEND=noninteractive apt -y install php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip git redis-server

  # enable services
  systemctl start mariadb
  systemctl enable mariadb
  systemctl start redis-server
  systemctl enable redis-server

  echo "* Dependencies for Debian 8/9 installed!"
}

function debian_dep {
  echo "* Installing dependencies for Debian 10.."

  # MariaDB need dirmngr
  DEBIAN_FRONTEND=noninteractive apt install -y dirmngr jq

  # install PHP 8.1 using sury's repo instead of default 7.2 package (in buster repo)
  DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates apt-transport-https lsb-release
  wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list

  # Update repositories list
  DEBIAN_FRONTEND=noninteractive apt update -y

  # install dependencies
  DEBIAN_FRONTEND=noninteractive apt -y install php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip git redis-server

  # enable services
  systemctl start mariadb
  systemctl enable mariadb
  systemctl start redis-server
  systemctl enable redis-server

  echo "* Dependencies for Debian 10 installed!"
}

function rhel7_dep {
  echo "* Installing dependencies for CentOS 7.."

  # update first
  yum update -y

  # SELinux tools
  yum install -y policycoreutils policycoreutils-python selinux-policy selinux-policy-targeted libselinux-utils setroubleshoot-server setools setools-console mcstrans jq

  # add remi repo (php8.1)
  yum install -y epel-release http://rpms.remirepo.net/enterprise/remi-release-7.rpm
  yum install -y yum-utils
  yum-config-manager -y --disable remi-php54
  yum-config-manager -y --enable remi-php74
  yum update -y

  # Install MariaDB
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # install dependencies
  yum -y install php php-common php-tokenizer php-curl php-fpm php-cli php-json php-mysqlnd php-mcrypt php-gd php-mbstring php-pdo php-zip php-bcmath php-dom php-opcache mariadb-server nginx curl tar zip unzip git redis

  # enable services
  systemctl enable mariadb
  systemctl enable redis
  systemctl start mariadb
  systemctl start redis

  # SELinux (allow nginx and redis)
  setsebool -P httpd_can_network_connect 1
  setsebool -P httpd_execmem 1
  setsebool -P httpd_unified 1

  echo "* Dependencies for CentOS installed!"
}

function rhel8_dep {
  echo "* Installing dependencies for RHEL.."

  # update first
  dnf update -y

  # SELinux tools
  dnf install -y policycoreutils selinux-policy selinux-policy-targeted setroubleshoot-server setools setools-console mcstrans jq

  # add remi repo (php8.1)
  dnf install -y epel-release http://rpms.remirepo.net/enterprise/remi-release-8.rpm
  dnf module enable -y php:remi-8.1
  dnf update -y

  dnf install -y php php-common php-fpm php-cli php-json php-mysqlnd php-gd php-mbstring php-pdo php-zip php-bcmath php-dom php-opcache

  # MariaDB (use from official repo)
  dnf install -y mariadb mariadb-server

  # Other dependencies
  dnf install -y nginx curl tar zip unzip git redis

  # enable services
  systemctl enable mariadb
  systemctl enable redis
  systemctl start mariadb
  systemctl start redis

  # SELinux (allow nginx and redis)
  setsebool -P httpd_can_network_connect 1
  setsebool -P httpd_execmem 1
  setsebool -P httpd_unified 1

  echo "* Dependencies for RHEL installed!"
}

#################################
## OTHER OS SPECIFIC FUNCTIONS ##
#################################

function ubuntu_universedep {
  # Probably should change this, this is more of a bandaid fix for this
  # This function is ran before software-properties-common is installed
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt install software-properties-common -y

  if grep -q universe "$SOURCES_PATH"; then
    # even if it detects it as already existent, we'll still run the apt command to make sure
    apt-add-repository universe -y
    echo "* Ubuntu universe repo already exists."
  else
    apt-add-repository universe -y
  fi
}

function centos_php {
  curl -o /etc/php-fpm.d/www-pterodactyl.conf $CONFIGS_URL/www-pterodactyl.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

function firewall_ufw {
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt install ufw -y

  echo -e "\n* Enabling Uncomplicated Firewall (UFW)"
  echo "* Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  # pointing to /dev/null silences the command output
  ufw allow ssh > /dev/null
  ufw allow http > /dev/null
  ufw allow https > /dev/null
  ufw allow 8080 comment "pterodactyl wings" > /dev/null
  ufw allow 2022 comment "pterodactyl sftp" > /dev/null

  ufw --force enable
  ufw status numbered | sed '/v6/d'
}

function firewall_firewalld {
  echo -e "\n* Enabling firewall_cmd (firewalld)"
  echo "* Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  if [ "$OS_VER_MAJOR" == "7" ]; then
    # pointing to /dev/null silences the command output
    echo "* Installing firewall"
    yum -y -q update > /dev/null
    yum -y -q install firewalld > /dev/null

    systemctl --now enable firewalld > /dev/null # Start and enable
    firewall-cmd --add-port 8080/tcp --permanent -q # Port 8080
    firewall-cmd --add-port 2022/tcp --permanent -q # Port 2022
    firewall-cmd --add-service=http --permanent -q # Port 80
    firewall-cmd --add-service=https --permanent -q # Port 443
    firewall-cmd --add-service=ssh --permanent -q  # Port 22
    firewall-cmd --reload -q # Enable firewall

  elif [ "$OS_VER_MAJOR" == "8" ]; then
    # pointing to /dev/null silences the command output
    echo "* Installing firewall"
    dnf -y -q update > /dev/null
    dnf -y -q install firewalld > /dev/null

    systemctl --now enable firewalld > /dev/null # Start and enable
    firewall-cmd --add-port 8080/tcp --permanent -q # Port 8080
    firewall-cmd --add-port 2022/tcp --permanent -q # Port 2022
    firewall-cmd --add-service=http --permanent -q # Port 80
    firewall-cmd --add-service=https --permanent -q # Port 443
    firewall-cmd --add-service=ssh --permanent -q  # Port 22
    firewall-cmd --reload -q # Enable firewall

  else
    print_error "Unsupported OS"
    exit 1
  fi

  echo "* Firewall-cmd installed"
  print_brake 70
}

function letsencrypt {
  FAILED=false

  # Install certbot
  if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
    DEBIAN_FRONTEND=noninteractive apt install -y snapd
    snap install core; sudo snap refresh core
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
  elif [ "$OS" == "centos" "$OS" == "almalinux" ]; then
    [ "$OS_VER_MAJOR" == "7" ] && yum install certbot
    [ "$OS_VER_MAJOR" == "8" || "$OS_VER_MAJOR" == "9" ] && dnf install certbot
  else
    # exit
    print_error "OS not supported."
    exit 1
  fi

  # Restart nginx
  systemctl restart nginx

}

#######################################
## WEBSERVER CONFIGURATION FUNCTIONS ##
#######################################

function configure_nginx {
  echo "* Configuring nginx .."
  DL_FILE="nginx.conf"

  if [ "$OS" == "centos" ] || [ "$OS" == "almalinux" ]; then
      # remove default config
      rm -rf /etc/nginx/conf.d/default

      # download new config
      curl -o /etc/nginx/conf.d/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/conf.d/pterodactyl.conf

      # replace all <php_socket> places with correct socket "path"
      sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" /etc/nginx/conf.d/pterodactyl.conf
  else
      # remove default config
      rm -rf /etc/nginx/sites-enabled/default

      # download new config
      curl -o /etc/nginx/sites-available/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-available/pterodactyl.conf

      # replace all <php_socket> places with correct socket "path"
      sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" /etc/nginx/sites-available/pterodactyl.conf

      # on debian 8/9, TLS v1.3 is not supported
      # this if statement can be refactored into a one-liner but I think this is more readable
      if [ "$OS" == "debian" ]; then
        if [ "$OS_VER_MAJOR" == "8" ] || [ "$OS_VER_MAJOR" == "9" ]; then
          sed -i 's/ TLSv1.3//' file /etc/nginx/sites-available/pterodactyl.conf
        fi
      fi

      # enable pterodactyl
      ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  fi

  # restart nginx
  systemctl restart nginx
  echo "* nginx configured!"
}

####################
## MAIN FUNCTIONS ##
####################

function perform_install {
  echo "* Starting installation.. this might take a while!"

  [ "$CONFIGURE_UFW" == true ] && firewall_ufw

  [ "$CONFIGURE_FIREWALL_CMD" == true ] && firewall_firewalld

  # do different things depending on OS
  if [ "$OS" == "ubuntu" ]; then
    ubuntu_universedep
    apt_update
    # different dependencies depending on if it's 22, 20 or 18
    if [ "$OS_VER_MAJOR" == "23" ] || [ "$OS_VER_MAJOR" == "22" ] || [ "$OS_VER_MAJOR" == "20" ] || [ "$OS_VER_MAJOR" == "18" ]; then
      ubuntu_dep
    else
      print_error "Unsupported version of Ubuntu."
      exit 1
    fi
    install_composer
    panel_ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
    install_docker
    ptdl_dl
    systemd_file

    if [ "$OS_VER_MAJOR" == "18" ] || [ "$OS_VER_MAJOR" == "20" ] || [ "$OS_VER_MAJOR" == "22" ] || [ "$OS_VER_MAJOR" == "23" ]; then
      if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
        letsencrypt
      fi
    fi
  elif [ "$OS" == "debian" ]; then
    apt_update
    if [ "$OS_VER_MAJOR" == "9" ]; then
      debian_stretch_dep
    elif [ "$OS_VER_MAJOR" == "10" ] || [ "$OS_VER_MAJOR" == "11" ] || [ "$OS_VER_MAJOR" == "12" ]; then
      debian_dep
    fi
    install_composer
    panel_ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
    install_docker
    ptdl_dl
    systemd_file

    if [ "$OS_VER_MAJOR" == "9" ] || [ "$OS_VER_MAJOR" == "10" ] || [ "$OS_VER_MAJOR" == "11" ] || [ "$OS_VER_MAJOR" == "12" ]; then
      if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
        letsencrypt
      fi
    fi
  elif [ "$OS" == "centos" || "$OS" == "almalinux" ]; then
    if [ "$OS_VER_MAJOR" == "7" ]; then
      rhel7_dep
    elif [ "$OS_VER_MAJOR" == "8" || "$OS_VER_MAJOR" == "9" ]; then
      rhel8_dep
    fi
    centos_php
    install_composer
    panel_ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
    install_docker
    ptdl_dl
    systemd_file
    if [ "$OS_VER_MAJOR" == "7" ] || [ "$OS_VER_MAJOR" == "8" ]; then
      if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
        letsencrypt
      fi
    fi
  else
    # exit
    print_error "OS not supported."
    exit 1
  fi

  # perform webserver configuration
  if [ "$WEBSERVER" == "nginx" ]; then
    configure_nginx
  else
    print_error "Invalid webserver."
    exit 1
  fi
}

function main {
  # check if we can detect an already existing installation
  if [ -d "/var/www/pterodactyl" ]; then
    print_warning "The script has detected that you already have Pterodactyl panel on your system! You cannot run the script multiple times, it will fail!"
    echo -e -n "* Are you sure you want to proceed? (y/N): "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
      print_error "Installation aborted!"
      exit 1
    fi
  fi

  # detect distro
  detect_distro

  # checks if the system is compatible with this installation script
  check_os_comp

  #set the timezone
  timezone="America/Chicago"

  # summary
  summary

  # confirm installation
  echo -e -n "\n* Continue with installation? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Yy] ]]; then
    perform_install
  else
    # run welcome script again
    print_error "Installation aborted."
    exit 1
  fi
  cp /var/www/pterodactyl/.env /etc/pterodactyl
}

function summary {
  print_brake 62
  echo "* Pterodactyl panel $PTERODACTYL_VERSION with $WEBSERVER on $OS"
  echo "* Panel URL: http://$FQDN"
  echo "* Username: $user_username"
  echo "* Password: $PASSWORD"
  print_brake 62
}

function goodbye {
  echo "* Panel installation completed"
  echo "*  ${COLOR_RED}Note${COLOR_NC}: Now follow the post installation process https://github.com/ForestRacks/PteroInstaller#post-installation"
}

# run script
main
summary
goodbye
