#!/bin/bash

# The MIT License (MIT)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -ex

#parameters 
{
    moodle_on_azure_configs_json_path=${1}

    . ./helper_functions.sh

    get_setup_params_from_configs_json $moodle_on_azure_configs_json_path || exit 99

    echo $moodleVersion                 >> /tmp/vars.txt
    echo $glusterNode                   >> /tmp/vars.txt
    echo $glusterVolume                 >> /tmp/vars.txt
    echo $siteFQDN                      >> /tmp/vars.txt
    echo $httpsTermination              >> /tmp/vars.txt
    echo $dbIP                          >> /tmp/vars.txt
    echo $moodledbname                  >> /tmp/vars.txt
    echo $moodledbuser                  >> /tmp/vars.txt
    echo $moodledbpass                  >> /tmp/vars.txt
    echo $adminpass                     >> /tmp/vars.txt
    echo $dbadminlogin                  >> /tmp/vars.txt
    echo $dbadminloginazure             >> /tmp/vars.txt
    echo $dbadminpass                   >> /tmp/vars.txt
    echo $storageAccountName            >> /tmp/vars.txt
    echo $storageAccountKey             >> /tmp/vars.txt
    echo $azuremoodledbuser             >> /tmp/vars.txt
    echo $redisDns                      >> /tmp/vars.txt
    echo $redisAuth                     >> /tmp/vars.txt
    echo $elasticVm1IP                  >> /tmp/vars.txt
    echo $installO365pluginsSwitch      >> /tmp/vars.txt
    echo $dbServerType                  >> /tmp/vars.txt
    echo $fileServerType                >> /tmp/vars.txt
    echo $mssqlDbServiceObjectiveName   >> /tmp/vars.txt
    echo $mssqlDbEdition                >> /tmp/vars.txt
    echo $mssqlDbSize                   >> /tmp/vars.txt
    echo $installObjectFsSwitch         >> /tmp/vars.txt
    echo $installGdprPluginsSwitch      >> /tmp/vars.txt
    echo $thumbprintSslCert             >> /tmp/vars.txt
    echo $thumbprintCaCert              >> /tmp/vars.txt
    echo $searchType                    >> /tmp/vars.txt
    echo $azureSearchKey                >> /tmp/vars.txt
    echo $azureSearchNameHost           >> /tmp/vars.txt
    echo $tikaVmIP                      >> /tmp/vars.txt
    echo $nfsByoIpExportPath            >> /tmp/vars.txt
    echo $storageAccountType            >>/tmp/vars.txt
    echo $fileServerDiskSize            >>/tmp/vars.txt
    echo $phpVersion                    >> /tmp/vars.txt
    echo $isMigration                   >> /tmp/vars.txt

    check_fileServerType_param $fileServerType

    if [ "$dbServerType" = "mysql" ]; then
      mysqlIP=$dbIP
      mysqladminlogin=$dbadminloginazure
      mysqladminpass=$dbadminpass
    elif [ "$dbServerType" = "mssql" ]; then
      mssqlIP=$dbIP
      mssqladminlogin=$dbadminloginazure
      mssqladminpass=$dbadminpass
    elif [ "$dbServerType" = "postgres" ]; then
      postgresIP=$dbIP
      pgadminlogin=$dbadminloginazure
      pgadminpass=$dbadminpass
    else
      echo "Invalid dbServerType ($dbServerType) given. Only 'mysql' or 'postgres' or 'mssql' is allowed. Exiting"
      exit 1
    fi

    #
    # Export apt default settings for this install script
    #

    apt_update_noninteractive >> /tmp/apt.log
    apt_install_noninteractive fail2ban >> /tmp/apt.log

    config_fail2ban

    # create gluster, nfs or Azure Files mount point
    mkdir -p /moodle

    if [ $fileServerType = "gluster" ]; then
        # configure gluster repository & install gluster clientapt 
        add-apt-repository ppa:gluster/glusterfs-9 --yes >> /tmp/apt.log
    elif [ $fileServerType = "nfs" ]; then
        # configure NFS server and export
        setup_raid_disk_and_filesystem /moodle /dev/md1 /dev/md1p1
        configure_nfs_server_and_export /moodle
    fi

    apt_update_noninteractive >> /tmp/apt.log
    apt_install_noninteractive rsyslog git >> /tmp/apt.log

    if [ $fileServerType = "gluster" ]; then
        apt_install_noninteractive glusterfs-client >> /tmp/apt.log
    elif [ "$fileServerType" = "azurefiles" ]; then
        apt_install_noninteractive \
            linux-modules-extra-azure \
            cifs-utils >> /tmp/apt.log

        # Because of https://bugs.launchpad.net/ubuntu/+source/linux-azure/+bug/2042092
        modprobe cifs && true
    fi

    if [ $dbServerType = "mysql" ]; then
        apt_install_noninteractive mysql-client >> /tmp/apt.log
    elif [ "$dbServerType" = "postgres" ]; then
        apt_install_noninteractive postgresql-client >> /tmp/apt.log
    fi

    if [ "$installObjectFsSwitch" = "true" -o "$fileServerType" = "azurefiles" ]; then
        # install azure cli
        AZ_REPO=$(lsb_release -cs)
        mkdir -p /etc/apt/keyrings
        curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg && chmod go+r /etc/apt/keyrings/microsoft.gpg
        echo "deb [arch=`dpkg --print-architecture` signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" > /etc/apt/sources.list.d/azure-cli.list

    apt_update_noninteractive >> /tmp/apt.log

    apt_install_noninteractive apt-transport-https ca-certificates curl apt-transport-https lsb-release gnupg azure-cli >> /tmp/apt.log

        # FileStorage accounts can only be used to store Azure file shares;
        # Premium_LRS will support FileStorage kind
        # No other storage resources (blob containers, queues, tables, etc.) can be deployed in a FileStorage account.
        if [ $storageAccountType != "Premium_LRS" ]; then
        az storage container create \
            --name objectfs \
            --account-name $storageAccountName \
            --account-key $storageAccountKey \
            --public-access off \
            --fail-on-exist >> /tmp/wabs.log

        az storage container policy create \
            --account-name $storageAccountName \
            --account-key $storageAccountKey \
            --container-name objectfs \
            --name readwrite \
            --start $(date --date="1 day ago" +%F) \
            --expiry $(date --date="2199-01-01" +%F) \
            --permissions rw >> /tmp/wabs.log

        sas=$(az storage container generate-sas \
            --account-name $storageAccountName \
            --account-key $storageAccountKey \
            --name objectfs \
            --policy readwrite \
            --output tsv)
        fi

        # If its a migration flow, then mount the azure file share now.
        if [ "$isMigration" = "true" ]; then
            # On migration flow, the moodle azure file share must present before running this script.
            echo -e '\n\rIts a migration flow, check whether moodle fileshare exists\n\r'
            check_azure_files_moodle_share_exists $storageAccountName $storageAccountKey
            
            # Set up and mount Azure Files share.
            echo -e '\n\rSetting up and mounting Azure Files share //'$storageAccountName'.file.core.windows.net/moodle on /moodle\n\r'
            setup_and_mount_azure_files_moodle_share $storageAccountName $storageAccountKey
        fi
    fi

    if [ $fileServerType = "gluster" ]; then
        # mount gluster files system
        echo -e '\n\rInstalling GlusterFS on '$glusterNode':/'$glusterVolume '/moodle\n\r' 
        setup_and_mount_gluster_moodle_share $glusterNode $glusterVolume
    elif [ $fileServerType = "nfs-ha" ]; then
        # mount NFS-HA export
        echo -e '\n\rMounting NFS export from '$nfsHaLbIP' on /moodle\n\r'
        configure_nfs_client_and_mount $nfsHaLbIP $nfsHaExportPath /moodle
    elif [ $fileServerType = "nfs-byo" ]; then
        # mount NFS-BYO export
        echo -e '\n\rMounting NFS export from '$nfsByoIpExportPath' on /moodle\n\r'
        configure_nfs_client_and_mount0 $nfsByoIpExportPath /moodle
    fi

    # install pre-requisites
    add-apt-repository ppa:ubuntu-toolchain-r/ppa --yes >> /tmp/apt.log
    apt_update_noninteractive >> /tmp/apt.log
    apt_install_noninteractive software-properties-common unzip >> /tmp/apt.log

    # install the entire stack
    apt_install_noninteractive \
        nginx \
        varnish \
        php \
        php-fpm \
        php-cli \
        php-curl \
        php-zip \
        graphviz \
        aspell \
        php-common \
        php-soap \
        php-json \
        php-redis \
        php-bcmath \
        php-ldap \
        php-gd \
        php-xmlrpc \
        php-intl \
        php-xml \
        php-bz2 \
        php-pear \
        php-mbstring \
        php-dev \
        mcrypt >> /tmp/apt.log

    PhpVer=$(get_php_version)
    if [ $dbServerType = "mysql" ]; then
        apt_install_noninteractive php-mysql
    elif [ $dbServerType = "mssql" ]; then
        apt_install_noninteractive libapache2-mod-php
        install_php_mssql_driver
    else
        apt_install_noninteractive php-pgsql
    fi

    # Set up initial moodle dirs
    mkdir -p /moodle/html
    mkdir -p /moodle/certs
    mkdir -p /moodle/moodledata

    o365pluginVersion=$(get_o365plugin_version_from_moodle_version $moodleVersion)
    moodleStableVersion=$o365pluginVersion  # Need Moodle stable version for GDPR plugins, and o365pluginVersion is just Moodle stable version, so reuse it.
    moodleUnzipDir=$(get_moodle_unzip_dir_from_moodle_version $moodleVersion)

    # install Moodle 
    cat <<EOF > /tmp/setup-moodle.sh
#!/bin/bash
mkdir -p /moodle/tmp
cd /moodle/tmp

if [ ! -d /moodle/html/moodle ]; then
    # downloading moodle only if /moodle/html/moodle does not exist -- if it exists, user should populate it in advance correctly as below. This is to reduce template deployment time.
    /usr/bin/curl -k --max-redirs 10 https://github.com/moodle/moodle/archive/MOODLE_405_STABLE.zip -L -o moodle.zip
    /usr/bin/unzip -q moodle.zip
    /bin/mv "$moodleUnzipDir" /moodle/html/moodle
fi

if [ "$installGdprPluginsSwitch" = "true" ]; then
    # install Moodle GDPR plugins (Note: This is only for Moodle versions 3.4.2+ or 3.3.5+ and will be included in Moodle 3.5, so no need for 3.5)
    curl -k --max-redirs 10 https://github.com/moodlehq/moodle-tool_policy/archive/"$moodleStableVersion".zip -L -o plugin-policy.zip
    unzip -q plugin-policy.zip
    mv moodle-tool_policy-"$moodleStableVersion" /moodle/html/moodle/admin/tool/policy

    curl -k --max-redirs 10 https://github.com/moodlehq/moodle-tool_dataprivacy/archive/"$moodleStableVersion".zip -L -o plugin-dataprivacy.zip
    unzip -q plugin-dataprivacy.zip
    mv moodle-tool_dataprivacy-"$moodleStableVersion" /moodle/html/moodle/admin/tool/dataprivacy
fi

if [ "$installO365pluginsSwitch" = "true" ]; then
    # install Office 365 plugins
    curl -k --max-redirs 10 https://github.com/Microsoft/o365-moodle/archive/"$o365pluginVersion".zip -L -o o365.zip
    unzip -q o365.zip
    cp -r o365-moodle-"$o365pluginVersion"/* /moodle/html/moodle
    rm -rf o365-moodle-"$o365pluginVersion"
fi

if [ "$searchType" = "elastic" ]; then
    # Install ElasticSearch plugin
    /usr/bin/curl -k --max-redirs 10 https://github.com/catalyst/moodle-search_elastic/archive/master.zip -L -o plugin-elastic.zip
    /usr/bin/unzip -q plugin-elastic.zip
    /bin/mv moodle-search_elastic-master /moodle/html/moodle/search/engine/elastic

    # Install ElasticSearch plugin dependency
    /usr/bin/curl -k --max-redirs 10 https://github.com/catalyst/moodle-local_aws/archive/master.zip -L -o local-aws.zip
    /usr/bin/unzip -q local-aws.zip
    /bin/mv moodle-local_aws-master /moodle/html/moodle/local/aws

elif [ "$searchType" = "azure" ]; then
    # Install Azure Search service plugin
    /usr/bin/curl -k --max-redirs 10 https://github.com/catalyst/moodle-search_azure/archive/master.zip -L -o plugin-azure-search.zip
    /usr/bin/unzip -q plugin-azure-search.zip
    /bin/mv moodle-search_azure-master /moodle/html/moodle/search/engine/azure
fi

if [ "$installObjectFsSwitch" = "true" ]; then
    # Install the ObjectFS plugin
    /usr/bin/curl -k --max-redirs 10 https://github.com/catalyst/moodle-tool_objectfs/archive/master.zip -L -o plugin-objectfs.zip
    /usr/bin/unzip -q plugin-objectfs.zip
    /bin/mv moodle-tool_objectfs-master /moodle/html/moodle/admin/tool/objectfs

    # Install the ObjectFS Azure library
    /usr/bin/curl -k --max-redirs 10 https://github.com/catalyst/moodle-local_azure_storage/archive/master.zip -L -o plugin-azurelibrary.zip
    /usr/bin/unzip -q plugin-azurelibrary.zip
    /bin/mv moodle-local_azure_storage-master /moodle/html/moodle/local/azure_storage
fi
cd /moodle
rm -rf /moodle/tmp
EOF

    chmod 755 /tmp/setup-moodle.sh
    /tmp/setup-moodle.sh >> /tmp/setupmoodle.log

    # Build nginx config
    cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes 2;
pid /run/nginx.pid;

events {
    worker_connections 768;
}

http {

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  types_hash_max_size 2048;
  client_max_body_size 0;
  proxy_max_temp_file_size 0;
  server_names_hash_bucket_size  128;
  fastcgi_buffers 16 16k; 
  fastcgi_buffer_size 32k;
  proxy_buffering off;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;

  set_real_ip_from   127.0.0.1;
  real_ip_header      X-Forwarded-For;
  #upgrading to TLSv1.2 and droping 1 & 1.1
  ssl_protocols TLSv1.2;
  #ssl_prefer_server_ciphers on;
  #adding ssl ciphers
  ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;


  gzip on;
  gzip_disable "msie6";
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript;
EOF

    if [ "$httpsTermination" != "None" ]; then
        cat <<EOF >> /etc/nginx/nginx.conf
  map \$http_x_forwarded_proto \$fastcgi_https {                                                                                          
    default \$https;                                                                                                                   
    http '';                                                                                                                          
    https on;                                                                                                                         
  }
EOF
    fi

    cat <<EOF >> /etc/nginx/nginx.conf
  log_format moodle_combined '\$remote_addr - \$upstream_http_x_moodleuser [\$time_local] '
                             '"\$request" \$status \$body_bytes_sent '
                             '"\$http_referer" "\$http_user_agent"';


  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-enabled/*;
}
EOF

    cat <<EOF >> /etc/nginx/sites-enabled/${siteFQDN}.conf
server {
        listen 81 default;
        server_name ${siteFQDN};
        root /moodle/html/moodle;
        index index.php index.html index.htm;

        # Log to syslog
        error_log syslog:server=localhost,facility=local1,severity=error,tag=moodle;
        access_log syslog:server=localhost,facility=local1,severity=notice,tag=moodle moodle_combined;

        # Log XFF IP instead of varnish
        set_real_ip_from    10.0.0.0/8;
        set_real_ip_from    127.0.0.1;
        set_real_ip_from    172.16.0.0/12;
        set_real_ip_from    192.168.0.0/16;
        real_ip_header      X-Forwarded-For;
        real_ip_recursive   on;
EOF
    if [ "$httpsTermination" != "None" ]; then
        cat <<EOF >> /etc/nginx/sites-enabled/${siteFQDN}.conf
        # Redirect to https
        if (\$http_x_forwarded_proto != https) {
                return 301 https://\$server_name\$request_uri;
        }
        rewrite ^/(.*\.php)(/)(.*)$ /\$1?file=/\$3 last;
EOF
    fi

    cat <<EOF >> /etc/nginx/sites-enabled/${siteFQDN}.conf
        # Filter out php-fpm status page
        location ~ ^/server-status {
            return 404;
        }

    location / {
        try_files \$uri \$uri/index.php?\$query_string;
    }
 
    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        if (!-f \$document_root\$fastcgi_script_name) {
                return 404;
        }

        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_param   SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php${PhpVer}-fpm.sock;
        fastcgi_read_timeout 3600;
        fastcgi_index index.php;
        include fastcgi_params;
    }
}
EOF
    if [ "$httpsTermination" = "VMSS" ]; then
        cat <<EOF >> /etc/nginx/sites-enabled/${siteFQDN}.conf
server {
        listen 443 ssl;
        root /moodle/html/moodle;
        index index.php index.html index.htm;

        ssl on;
        ssl_certificate /moodle/certs/nginx.crt;
        ssl_certificate_key /moodle/certs/nginx.key;

        # Log to syslog
        error_log syslog:server=localhost,facility=local1,severity=error,tag=moodle;
        access_log syslog:server=localhost,facility=local1,severity=notice,tag=moodle moodle_combined;

        # Log XFF IP instead of varnish
        set_real_ip_from    10.0.0.0/8;
        set_real_ip_from    127.0.0.1;
        set_real_ip_from    172.16.0.0/12;
        set_real_ip_from    192.168.0.0/16;
        real_ip_header      X-Forwarded-For;
        real_ip_recursive   on;

        location / {
          proxy_set_header Host \$host;
          proxy_set_header HTTP_REFERER \$http_referer;
          proxy_set_header X-Forwarded-Host \$host;
          proxy_set_header X-Forwarded-Server \$host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_pass http://localhost:80;
        }
}
EOF
    fi

    if [ "$httpsTermination" = "VMSS" ]; then
        ### SSL cert ###
        if [ "$thumbprintSslCert" != "None" ]; then
            echo "Using VM's cert (/var/lib/waagent/$thumbprintSslCert.*) for SSL..."
            cat /var/lib/waagent/$thumbprintSslCert.prv > /moodle/certs/nginx.key
            cat /var/lib/waagent/$thumbprintSslCert.crt > /moodle/certs/nginx.crt
            if [ "$thumbprintCaCert" != "None" ]; then
                echo "CA cert was specified (/var/lib/waagent/$thumbprintCaCert.crt), so append it to nginx.crt..."
                cat /var/lib/waagent/$thumbprintCaCert.crt >> /moodle/certs/nginx.crt
            fi
        else
            echo -e "Generating SSL self-signed certificate"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /moodle/certs/nginx.key -out /moodle/certs/nginx.crt -subj "/C=US/ST=WA/L=Redmond/O=IT/CN=$siteFQDN"
        fi
        chown www-data:www-data /moodle/certs/nginx.*
        chmod 0400 /moodle/certs/nginx.*
    fi

   # PHP 8 fpm config
   PhpVer=$(get_php_version)
   PhpIni=/etc/php/${PhpVer}/fpm/php.ini
   sed -i "s/memory_limit.*/memory_limit = 512M/" $PhpIni
   sed -i "s/max_execution_time.*/max_execution_time = 18000/" $PhpIni
   sed -i "s/;max_input_vars.*/max_input_vars = 100000/" $PhpIni
   sed -i "s/max_input_time.*/max_input_time = 600/" $PhpIni
   sed -i "s/upload_max_filesize.*/upload_max_filesize = 1024M/" $PhpIni
   sed -i "s/post_max_size.*/post_max_size = 1056M/" $PhpIni
   sed -i "s/;opcache.use_cwd.*/opcache.use_cwd = 1/" $PhpIni
   sed -i "s/;opcache.validate_timestamps.*/opcache.validate_timestamps = 1/" $PhpIni
   sed -i "s/;opcache.save_comments.*/opcache.save_comments = 1/" $PhpIni
   sed -i "s/;opcache.enable_file_override.*/opcache.enable_file_override = 0/" $PhpIni
   sed -i "s/;opcache.enable.*/opcache.enable = 1/" $PhpIni
   sed -i "s/;opcache.memory_consumption.*/opcache.memory_consumption = 256/" $PhpIni
   sed -i "s/;opcache.max_accelerated_files.*/opcache.max_accelerated_files = 8000/" $PhpIni

   # required for PHP8 cli at install time
   PhpIniCli=/etc/php/${PhpVer}/cli/php.ini
   sed -i "s/;max_input_vars.*/max_input_vars = 100000/" $PhpIniCli

   # fpm config - overload this 
   cat <<EOF > /etc/php/${PhpVer}/fpm/pool.d/www.conf
[www]
user = www-data
group = www-data
listen = /run/php/php${PhpVer}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 3000
pm.start_servers = 20 
pm.min_spare_servers = 22 
pm.max_spare_servers = 30 
EOF

   # Remove the default site. Moodle is the only site we want
   rm -f /etc/nginx/sites-enabled/default

   # restart Nginx
   sudo service nginx restart 

   # Configure varnish startup for 16.04
   VARNISHSTART="ExecStart=\/usr\/sbin\/varnishd -j unix,user=vcache -F -a :80 -T localhost:6082 -f \/etc\/varnish\/moodle.vcl -S \/etc\/varnish\/secret -s malloc,1024m -p thread_pool_min=200 -p thread_pool_max=4000 -p thread_pool_add_delay=2 -p timeout_linger=100 -p timeout_idle=30 -p send_timeout=1800 -p thread_pools=4 -p http_max_hdr=512 -p workspace_backend=512k"
   sed -i "s/^ExecStart.*/${VARNISHSTART}/" /lib/systemd/system/varnish.service

   # Configure varnish VCL for moodle
   cat <<EOF >> /etc/varnish/moodle.vcl
vcl 4.0;

import std;
import directors;
backend default {
    .host = "localhost";
    .port = "81";
    .first_byte_timeout = 3600s;
    .connect_timeout = 600s;
    .between_bytes_timeout = 600s;
}

sub vcl_recv {
    # Varnish does not support SPDY or HTTP/2.0 untill we upgrade to Varnish 5.0
    if (req.method == "PRI") {
        return (synth(405));
    }

    if (req.restarts == 0) {
      if (req.http.X-Forwarded-For) {
        set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
      } else {
        set req.http.X-Forwarded-For = client.ip;
      }
    }

    # Non-RFC2616 or CONNECT HTTP requests methods filtered. Pipe requests directly to backend
    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "DELETE") {
      return (pipe);
    }

    # Varnish don't mess with healthchecks
    if (req.url ~ "^/admin/tool/heartbeat" || req.url ~ "^/healthcheck.php")
    {
        return (pass);
    }

    # Pipe requests to backup.php straight to backend - prevents problem with progress bar long polling 503 problem
    # This is here because backup.php is POSTing to itself - Filter before !GET&&!HEAD
    if (req.url ~ "^/backup/backup.php")
    {
        return (pipe);
    }

    # Varnish only deals with GET and HEAD by default. If request method is not GET or HEAD, pass request to backend
    if (req.method != "GET" && req.method != "HEAD") {
      return (pass);
    }

    ### Rules for Moodle and Totara sites ###
    # Moodle doesn't require Cookie to serve following assets. Remove Cookie header from request, so it will be looked up.
    if ( req.url ~ "^/altlogin/.+/.+\.(png|jpg|jpeg|gif|css|js|webp)$" ||
         req.url ~ "^/pix/.+\.(png|jpg|jpeg|gif)$" ||
         req.url ~ "^/theme/font.php" ||
         req.url ~ "^/theme/image.php" ||
         req.url ~ "^/theme/javascript.php" ||
         req.url ~ "^/theme/jquery.php" ||
         req.url ~ "^/theme/styles.php" ||
         req.url ~ "^/theme/yui" ||
         req.url ~ "^/lib/javascript.php/-1/" ||
         req.url ~ "^/lib/requirejs.php/-1/"
        )
    {
        set req.http.X-Long-TTL = "86400";
        unset req.http.Cookie;
        return(hash);
    }

    # Perform lookup for selected assets that we know are static but Moodle still needs a Cookie
    if(  req.url ~ "^/theme/.+\.(png|jpg|jpeg|gif|css|js|webp)" ||
         req.url ~ "^/lib/.+\.(png|jpg|jpeg|gif|css|js|webp)" ||
         req.url ~ "^/pluginfile.php/[0-9]+/course/overviewfiles/.+\.(?i)(png|jpg)$"
      )
    {
         # Set internal temporary header, based on which we will do things in vcl_backend_response
         set req.http.X-Long-TTL = "86400";
         return (hash);
    }

    # Serve requests to SCORM checknet.txt from varnish. Have to remove get parameters. Response body always contains "1"
    if ( req.url ~ "^/lib/yui/build/moodle-core-checknet/assets/checknet.txt" )
    {
        set req.url = regsub(req.url, "(.*)\?.*", "\1");
        unset req.http.Cookie; # Will go to hash anyway at the end of vcl_recv
        set req.http.X-Long-TTL = "86400";
        return(hash);
    }

    # Requests containing "Cookie" or "Authorization" headers will not be cached
    if (req.http.Authorization || req.http.Cookie) {
        return (pass);
    }

    # Almost everything in Moodle correctly serves Cache-Control headers, if
    # needed, which varnish will honor, but there are some which don't. Rather
    # than explicitly finding them all and listing them here we just fail safe
    # and don't cache unknown urls that get this far.
    return (pass);
}

sub vcl_backend_response {
    # Happens after we have read the response headers from the backend.
    # 
    # Here you clean the response headers, removing silly Set-Cookie headers
    # and other mistakes your backend does.

    # We know these assest are static, let's set TTL >0 and allow client caching
    if ( beresp.http.Cache-Control && bereq.http.X-Long-TTL && beresp.ttl < std.duration(bereq.http.X-Long-TTL + "s", 1s) && !beresp.http.WWW-Authenticate )
    { # If max-age < defined in X-Long-TTL header
        set beresp.http.X-Orig-Pragma = beresp.http.Pragma; unset beresp.http.Pragma;
        set beresp.http.X-Orig-Cache-Control = beresp.http.Cache-Control;
        set beresp.http.Cache-Control = "public, max-age="+bereq.http.X-Long-TTL+", no-transform";
        set beresp.ttl = std.duration(bereq.http.X-Long-TTL + "s", 1s);
        unset bereq.http.X-Long-TTL;
    }
    else if( !beresp.http.Cache-Control && bereq.http.X-Long-TTL && !beresp.http.WWW-Authenticate ) {
        set beresp.http.X-Orig-Pragma = beresp.http.Pragma; unset beresp.http.Pragma;
        set beresp.http.Cache-Control = "public, max-age="+bereq.http.X-Long-TTL+", no-transform";
        set beresp.ttl = std.duration(bereq.http.X-Long-TTL + "s", 1s);
        unset bereq.http.X-Long-TTL;
    }
    else { # Don't touch headers if max-age > defined in X-Long-TTL header
        unset bereq.http.X-Long-TTL;
    }

    # Here we set X-Trace header, prepending it to X-Trace header received from backend. Useful for troubleshooting
    if(beresp.http.x-trace && !beresp.was_304) {
        set beresp.http.X-Trace = regsub(server.identity, "^([^.]+),?.*$", "\1")+"->"+regsub(beresp.backend.name, "^(.+)\((?:[0-9]{1,3}\.){3}([0-9]{1,3})\)","\1(\2)")+"->"+beresp.http.X-Trace;
    }
    else {
        set beresp.http.X-Trace = regsub(server.identity, "^([^.]+),?.*$", "\1")+"->"+regsub(beresp.backend.name, "^(.+)\((?:[0-9]{1,3}\.){3}([0-9]{1,3})\)","\1(\2)");
    }

    # Gzip JS, CSS is done at the ngnix level doing it here dosen't respect the no buffer requsets
    # if (beresp.http.content-type ~ "application/javascript.*" || beresp.http.content-type ~ "text") {
    #    set beresp.do_gzip = true;
    #}
}

sub vcl_deliver {

    # Revert back to original Cache-Control header before delivery to client
    if (resp.http.X-Orig-Cache-Control)
    {
        set resp.http.Cache-Control = resp.http.X-Orig-Cache-Control;
        unset resp.http.X-Orig-Cache-Control;
    }

    # Revert back to original Pragma header before delivery to client
    if (resp.http.X-Orig-Pragma)
    {
        set resp.http.Pragma = resp.http.X-Orig-Pragma;
        unset resp.http.X-Orig-Pragma;
    }

    # (Optional) X-Cache HTTP header will be added to responce, indicating whether object was retrieved from backend, or served from cache
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }

    # Set X-AuthOK header when totara/varnsih authentication succeeded
    if (req.http.X-AuthOK) {
        set resp.http.X-AuthOK = req.http.X-AuthOK;
    }

    # If desired "Via: 1.1 Varnish-v4" response header can be removed from response
    unset resp.http.Via;
    unset resp.http.Server;

    return(deliver);
}

sub vcl_backend_error {
    # More comprehensive varnish error page. Display time, instance hostname, host header, url for easier troubleshooting.
    set beresp.http.Content-Type = "text/html; charset=utf-8";
    set beresp.http.Retry-After = "5";
    synthetic( {"
  <!DOCTYPE html>
  <html>
    <head>
      <title>"} + beresp.status + " " + beresp.reason + {"</title>
    </head>
    <body>
      <h1>Error "} + beresp.status + " " + beresp.reason + {"</h1>
      <p>"} + beresp.reason + {"</p>
      <h3>Guru Meditation:</h3>
      <p>Time: "} + now + {"</p>
      <p>Node: "} + server.hostname + {"</p>
      <p>Host: "} + bereq.http.host + {"</p>
      <p>URL: "} + bereq.url + {"</p>
      <p>XID: "} + bereq.xid + {"</p>
      <hr>
      <p>Varnish cache server
    </body>
  </html>
  "} );
   return (deliver);
}

sub vcl_synth {

    #Redirect using '301 - Permanent Redirect', permanent redirect
    if (resp.status == 851) { 
        set resp.http.Location = req.http.x-redir;
        set resp.http.X-Varnish-Redirect = true;
        set resp.status = 301;
        return (deliver);
    }

    #Redirect using '302 - Found', temporary redirect
    if (resp.status == 852) { 
        set resp.http.Location = req.http.x-redir;
        set resp.http.X-Varnish-Redirect = true;
        set resp.status = 302;
        return (deliver);
    }

    #Redirect using '307 - Temporary Redirect', !GET&&!HEAD requests, dont change method on redirected requests
    if (resp.status == 857) { 
        set resp.http.Location = req.http.x-redir;
        set resp.http.X-Varnish-Redirect = true;
        set resp.status = 307;
        return (deliver);
    }

    #Respond with 403 - Forbidden
    if (resp.status == 863) {
        set resp.http.X-Varnish-Error = true;
        set resp.status = 403;
        return (deliver);
    }
}
EOF

    # Restart Varnish
    systemctl daemon-reload
    service varnish restart

    if [ $dbServerType = "mysql" ]; then
        mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} -e "CREATE DATABASE ${moodledbname} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | tee -a /tmp/debug
        mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} -e "CREATE USER ${moodledbuser}@'%' IDENTIFIED BY '${moodledbpass}';" | tee -a /tmp/debug
        mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,CREATE TEMPORARY TABLES,DROP,INDEX,ALTER ON ${moodledbname}.* TO ${moodledbuser}@'%';" | tee -a /tmp/debug

    elif [ $dbServerType = "mssql" ]; then
        /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -Q "CREATE DATABASE ${moodledbname} ( MAXSIZE = $mssqlDbSize, EDITION = '$mssqlDbEdition', SERVICE_OBJECTIVE = '$mssqlDbServiceObjectiveName' )"
        /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -Q "CREATE LOGIN ${moodledbuser} with password = '${moodledbpass}'" 
        /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "CREATE USER ${moodledbuser} FROM LOGIN ${moodledbuser}"
        /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "exec sp_addrolemember 'db_owner','${moodledbuser}'" 
        
    else
        # Create postgres db
        echo "${postgresIP}:5432:postgres:${pgadminlogin}:${pgadminpass}" > /root/.pgpass
        chmod 600 /root/.pgpass
        psql -h $postgresIP -U $pgadminlogin -c "CREATE DATABASE ${moodledbname};" postgres
        psql -h $postgresIP -U $pgadminlogin -c "CREATE USER ${moodledbuser} WITH PASSWORD '${moodledbpass}';" postgres
        psql -h $postgresIP -U $pgadminlogin -c "GRANT ALL ON DATABASE ${moodledbname} TO ${moodledbuser};" postgres
        rm -f /root/.pgpass
    fi

    # Master config for syslog
    mkdir /var/log/sitelogs
    chown syslog.adm /var/log/sitelogs
    cat <<EOF >> /etc/rsyslog.conf
\$ModLoad imudp
\$UDPServerRun 514
EOF
    cat <<EOF >> /etc/rsyslog.d/40-sitelogs.conf
local1.*   /var/log/sitelogs/moodle/access.log
local1.err   /var/log/sitelogs/moodle/error.log
local2.*   /var/log/sitelogs/moodle/cron.log
EOF
    service rsyslog restart

    # Fire off moodle setup
    if [ "$httpsTermination" = "None" ]; then
        siteProtocol="http"
    else
        siteProtocol="https"
    fi
    if [ $dbServerType = "mysql" ]; then
        if [ "$isMigration" = "true" ]; then
            echo "Importing database from the mysql dump file"
            if [ ! -f /moodle/migration-db-moodle.sql.tar.gz ]; then
              echo "Migrating moodle DB dump archive file not found."
              exit 1
            fi
            
            tar -xvf /moodle/migration-db-moodle.sql.tar.gz -C /moodle/
            
            if [ ! -f /moodle/migration-db-moodle.sql ]; then
              echo "Migrating moodle DB dump file not found."
              exit 1
            fi
            
            echo "Importing migration moodle DB."
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} < /moodle/migration-db-moodle.sql
            
            echo "Updating moodle db config settings"
            replace_moodle_config_value "dbhost" "$mysqlIP"
            replace_moodle_config_value "dbuser" "$azuremoodledbuser"
            replace_moodle_config_value "dbpass" "$moodledbpass"
            
            echo "Updating other moodle config settings"
            replace_moodle_config_value "dataroot" "\/moodle\/moodledata"
            replace_moodle_config_value "wwwroot" "$siteProtocol:\/\/$siteFQDN"
        else
            echo -e "cd /tmp; /usr/bin/php /moodle/html/moodle/admin/cli/install.php --chmod=770 --lang=en --wwwroot="$siteProtocol"://"$siteFQDN" --dataroot=/moodle/moodledata --dbhost="$mysqlIP" --dbname="$moodledbname" --dbuser="$azuremoodledbuser" --dbpass="$moodledbpass" --dbtype=mysqli --fullname='Moodle LMS' --shortname='Moodle' --adminuser=admin --adminpass="$adminpass" --adminemail=admin@"$siteFQDN" --non-interactive --agree-license --allow-unstable || true "
            cd /tmp; /usr/bin/php /moodle/html/moodle/admin/cli/install.php --chmod=770 --lang=en --wwwroot=$siteProtocol://$siteFQDN   --dataroot=/moodle/moodledata --dbhost=$mysqlIP   --dbname=$moodledbname   --dbuser=$azuremoodledbuser   --dbpass=$moodledbpass   --dbtype=mysqli --fullname='Moodle LMS' --shortname='Moodle' --adminuser=admin --adminpass=$adminpass   --adminemail=admin@$siteFQDN   --non-interactive --agree-license --allow-unstable || true
        fi

        if [ "$installObjectFsSwitch" = "true" ]; then
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} -e "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'enabletasks', 1);" 
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} -e "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'filesystem', '\\\tool_objectfs\\\azure_file_system');"
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} -e "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_accountname', '${storageAccountName}');"
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} -e "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_container', 'objectfs');"
            mysql -h $mysqlIP -u $mysqladminlogin -p${mysqladminpass} ${moodledbname} -e "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_sastoken', '${sas}');"
        fi
    elif [ $dbServerType = "mssql" ]; then
        cd /tmp; /usr/bin/php /moodle/html/moodle/admin/cli/install.php --chmod=770 --lang=en --wwwroot=$siteProtocol://$siteFQDN   --dataroot=/moodle/moodledata --dbhost=$mssqlIP   --dbname=$moodledbname   --dbuser=$azuremoodledbuser   --dbpass=$moodledbpass   --dbtype=sqlsrv --fullname='Moodle LMS' --shortname='Moodle' --adminuser=admin --adminpass=$adminpass   --adminemail=admin@$siteFQDN   --non-interactive --agree-license --allow-unstable || true

        if [ "$installObjectFsSwitch" = "true" ]; then
            /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'enabletasks', 1)" 
            /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'filesystem', '\\\tool_objectfs\\\azure_file_system')"
            /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_accountname', '${storageAccountName}')"
            /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d ${moodledbname} -Q "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_container', 'objectfs')"
            /opt/mssql-tools/bin/sqlcmd -S $mssqlIP -U $mssqladminlogin -P ${mssqladminpass} -d${moodledbname} -Q "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_sastoken', '${sas}')"
        fi
    else
        echo -e "cd /tmp; /usr/bin/php /moodle/html/moodle/admin/cli/install.php --chmod=770 --lang=en --wwwroot="$siteProtocol"://"$siteFQDN" --dataroot=/moodle/moodledata --dbhost="$postgresIP" --dbname="$moodledbname" --dbuser="$azuremoodledbuser" --dbpass="$moodledbpass" --dbtype=pgsql --fullname='Moodle LMS' --shortname='Moodle' --adminuser=admin --adminpass="$adminpass" --adminemail=admin@"$siteFQDN" --non-interactive --agree-license --allow-unstable || true "
        cd /tmp; /usr/bin/php /moodle/html/moodle/admin/cli/install.php --chmod=770 --lang=en --wwwroot=$siteProtocol://$siteFQDN   --dataroot=/moodle/moodledata --dbhost=$postgresIP   --dbname=$moodledbname   --dbuser=$azuremoodledbuser   --dbpass=$moodledbpass   --dbtype=pgsql --fullname='Moodle LMS' --shortname='Moodle' --adminuser=admin --adminpass=$adminpass   --adminemail=admin@$siteFQDN   --non-interactive --agree-license --allow-unstable || true

        if [ "$installObjectFsSwitch" = "true" ]; then
            # Add the ObjectFS configuration to Moodle.
            echo "${postgresIP}:5432:${moodledbname}:${azuremoodledbuser}:${moodledbpass}" > /root/.pgpass
            chmod 600 /root/.pgpass
            psql -h $postgresIP -U $azuremoodledbuser -c "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'enabletasks', 1);" $moodledbname
            psql -h $postgresIP -U $azuremoodledbuser -c "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'filesystem', '\tool_objectfs\azure_file_system');" $moodledbname
            psql -h $postgresIP -U $azuremoodledbuser -c "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_accountname', '$storageAccountName');" $moodledbname
            psql -h $postgresIP -U $azuremoodledbuser -c "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_container', 'objectfs');" $moodledbname
            psql -h $postgresIP -U $azuremoodledbuser -c "INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('tool_objectfs', 'azure_sastoken', '$sas');" $moodledbname
        fi
    fi

    echo -e "\n\rDone! Installation completed!\n\r"
    
    # use /tmp/localcachedir/ for localcache and /var/www/html/moodle/ for core_component.php
    dir="/var/www/html/moodle"
    if [[ ! -d $dir ]]; then
        mkdir -p $dir
    fi
    sed -i "22 a \$CFG->localcachedir = '/tmp/localcachedir';" /moodle/html/moodle/config.php
    sed -i "22 a \$CFG->alternative_component_cache = '/var/www/html/moodle/core_component.php';" /moodle/html/moodle/config.php
    chown -R www-data:www-data $dir
    chgrp www-data $dir
    chmod g+s $dir
    
    if [ "$redisAuth" != "None" ]; then
        create_redis_configuration_in_moodledata_muc_config_php

        # redis configuration in /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_lock_expire = 7200;" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_acquire_lock_timeout = 120;" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_prefix = 'moodle_prod'; // Optional, default is don't set one." /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_database = 0;  // Optional, default is db 0." /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_port = 6379;  // Optional." /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_host = '$redisDns';" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_redis_auth = '$redisAuth';" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->session_handler_class = '\\\core\\\session\\\redis';" /moodle/html/moodle/config.php
    fi

    if [ "$httpsTermination" != "None" ]; then
        # We proxy ssl, so moodle needs to know this
        sed -i "23 a \$CFG->sslproxy  = 'true';" /moodle/html/moodle/config.php
    fi

    if [ "$searchType" = "elastic" ]; then
        # Set up elasticsearch plugin
        if [ "$tikaVmIP" = "none" ]; then
           sed -i "23 a \$CFG->forced_plugin_settings = ['search_elastic' => ['hostname' => 'http://$elasticVm1IP']];" /moodle/html/moodle/config.php
        else
           sed -i "23 a \$CFG->forced_plugin_settings = ['search_elastic' => ['hostname' => 'http://$elasticVm1IP', 'fileindexing' => 'true', 'tikahostname' => 'http://$tikaVmIP', 'tikaport' => '9998'],];" /moodle/html/moodle/config.php
        fi

        sed -i "23 a \$CFG->searchengine = 'elastic';" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->enableglobalsearch = 'true';" /moodle/html/moodle/config.php
        # create index
        php /moodle/html/moodle/search/cli/indexer.php --force --reindex || true

    elif [ "$searchType" = "azure" ]; then
        # Set up Azure Search service plugin
        if [ "$tikaVmIP" = "none" ]; then
           sed -i "23 a \$CFG->forced_plugin_settings = ['search_azure' => ['searchurl' => 'https://$azureSearchNameHost', 'apikey' => '$azureSearchKey']];" /moodle/html/moodle/config.php
        else
           sed -i "23 a \$CFG->forced_plugin_settings = ['search_azure' => ['searchurl' => 'https://$azureSearchNameHost', 'apikey' => '$azureSearchKey', 'fileindexing' => '1', 'tikahostname' => 'http://$tikaVmIP', 'tikaport' => '9998'],];" /moodle/html/moodle/config.php
        fi

        sed -i "23 a \$CFG->searchengine = 'azure';" /moodle/html/moodle/config.php
        sed -i "23 a \$CFG->enableglobalsearch = 'true';" /moodle/html/moodle/config.php
        # create index
        php /moodle/html/moodle/search/cli/indexer.php --force --reindex || true

    fi

    if [ "$installObjectFsSwitch" = "true" ]; then
        # Set the ObjectFS alternate filesystem
        sed -i "23 a \$CFG->alternative_file_system_class = '\\\tool_objectfs\\\azure_file_system';" /moodle/html/moodle/config.php
    fi

   if [ "$dbServerType" = "postgres" ]; then
     # Get a new version of Postgres to match Azure version
     add-apt-repository "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main"
     wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE='a' apt -key add -
     apt-get update
     apt-get install -y postgresql-client-9.6
   fi

   # create cron entry
   # It is scheduled for once per minute. It can be changed as needed.
   echo '* * * * * www-data /usr/bin/php /moodle/html/moodle/admin/cli/cron.php 2>&1 | /usr/bin/logger -p local2.notice -t moodle' > /etc/cron.d/moodle-cron

   # Set up cronned sql dump
   if [ "$dbServerType" = "mysql" ]; then
      cat <<EOF > /etc/cron.d/sql-backup
22 02 * * * root /usr/bin/mysqldump -h $mysqlIP -u ${azuremoodledbuser} -p'${moodledbpass}' --databases ${moodledbname} | gzip > /moodle/db-backup.sql.gz
EOF
   elif [ "$dbServerType" = "postgres" ]; then
      cat <<EOF > /etc/cron.d/sql-backup
22 02 * * * root /usr/bin/pg_dump -Fc -h $postgresIP -U ${azuremoodledbuser} ${moodledbname} > /moodle/db-backup.sql
EOF
   #else # mssql. TODO It's missed earlier! Complete this!
   fi

   # Turning off services we don't need the controller running
   service nginx stop
   service php${PhpVer}-fpm stop
   service varnish stop
   service varnishncsa stop
   #service varnishlog stop

    # No need to run the commands below any more, as permissions & modes are already as such (no more "sudo -u www-data ...")
    # Leaving this code as a remark that we are explicitly leaving the ownership to root:root
#    if [ $fileServerType = "gluster" -o $fileServerType = "nfs" -o $fileServerType = "nfs-ha" ]; then
#       # make sure Moodle can read its code directory but not write
#       sudo chown -R root.root /moodle/html/moodle
#       sudo find /moodle/html/moodle -type f -exec chmod 644 '{}' \;
#       sudo find /moodle/html/moodle -type d -exec chmod 755 '{}' \;
#    fi
    # But now we need to adjust the moodledata and the certs directory ownerships, and the permission for the generated config.php
    sudo chown -R www-data.www-data /moodle/moodledata /moodle/certs
    sudo chmod +r /moodle/html/moodle/config.php

    # chmod /moodle for Azure NetApp Files (its default is 770!)
    if [ $fileServerType = "nfs-byo" ]; then
        sudo chmod +rx /moodle
    fi

   if [ $fileServerType = "azurefiles" ]; then
      if [ "$isMigration" = "true" ]; then
        echo -e '\n\rIts a migration flow, the moodle content is already on azure file share\n\r'
      else
         # Delayed copy of moodle installation to the Azure Files share

         # First rename moodle directory to something else
         mv /moodle /moodle_old_delete_me
         # Then create the moodle share
         echo -e '\n\rCreating an Azure Files share for moodle'
         create_azure_files_moodle_share $storageAccountName $storageAccountKey /tmp/wabs.log $fileServerDiskSize
         # Set up and mount Azure Files share. Must be done after nginx is installed because of www-data user/group
         echo -e '\n\rSetting up and mounting Azure Files share on //'$storageAccountName'.file.core.windows.net/moodle on /moodle\n\r'
         setup_and_mount_azure_files_moodle_share $storageAccountName $storageAccountKey
         # Move the local installation over to the Azure Files
         echo -e '\n\rMoving locally installed moodle over to Azure Files'

         # install azcopy
         wget -q -O azcopy_v10.tar.gz https://aka.ms/downloadazcopy-v10-linux && tar -xf azcopy_v10.tar.gz --strip-components=1 && mv ./azcopy /usr/bin/
      
         ACCOUNT_KEY="$storageAccountKey"
         NAME="$storageAccountName"
         END=`date -u -d "60 minutes" '+%Y-%m-%dT%H:%M:00Z'`

         sas=$(az storage share generate-sas \
           -n moodle \
           --account-key $ACCOUNT_KEY \
           --account-name $NAME \
           --https-only \
           --permissions lrw \
           --expiry $END -o tsv)

         export AZCOPY_CONCURRENCY_VALUE='48'
         export AZCOPY_BUFFER_GB='4'

         # cp -a /moodle_old_delete_me/* /moodle || true # Ignore case sensitive directory copy failure
         azcopy --log-level ERROR copy "/moodle_old_delete_me/*" "https://$NAME.file.core.windows.net/moodle?$sas" --recursive || true # Ignore case sensitive directory copy failure
         rm -rf /moodle_old_delete_me || true # Keep the files just in case
      fi
   fi

   create_last_modified_time_update_script
   run_once_last_modified_time_update_script

   echo "### Script End `date`###"

}  2>&1 | tee /tmp/install.log
