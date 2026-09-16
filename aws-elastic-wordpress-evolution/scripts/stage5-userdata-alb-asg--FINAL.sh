#!/bin/bash -xe

# ==============================================================================
# STAGE 5: FINAL USER DATA SCRIPT (ALB + ASG + EFS + RDS MULTI-AZ)
# ==============================================================================

# 1. Fetch Configuration Parameters from AWS Systems Manager Parameter Store
ALBDNSNAME=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/ALBDNSNAME --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')
EFSFSID=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/EFSFSID --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')
DBPassword=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/DBPassword --with-decryption --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')
DBUser=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/DBUser --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')
DBName=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/DBName --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')
DBEndpoint=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/DBEndpoint --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')

# 2. Update System Packages & Install Dependencies
dnf -y update
dnf install -y wget php-mysqlnd httpd php-fpm php-mysqli mariadb105 php-json php php-devel amazon-efs-utils php-gd stress

# 3. Enable and Start Apache Web Server
systemctl enable httpd
systemctl start httpd

# 4. Download and Extract Latest WordPress Core
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -zxvf latest.tar.gz
cp -rvf wordpress/* .
rm -rf wordpress latest.tar.gz

# 5. Configure WordPress Database Connection (Targeting Amazon RDS)
cp ./wp-config-sample.php ./wp-config.php
sed -i "s/'database_name_here'/'$DBName'/g" wp-config.php
sed -i "s/'username_here'/'$DBUser'/g" wp-config.php
sed -i "s/'password_here'/'$DBPassword'/g" wp-config.php
sed -i "s/'localhost'/'$DBEndpoint'/g" wp-config.php

# 6. Mount Amazon EFS File System (Strictly scoped to wp-content/uploads)
mkdir -p /var/www/html/wp-content/uploads
echo -e "$EFSFSID:/ /var/www/html/wp-content/uploads efs _netdev,tls,iam 0 0" >> /etc/fstab
mount -a -t efs defaults

# 7. Apply Hardened Web Directory Permissions
usermod -a -G apache ec2-user
chown -R ec2-user:apache /var/www
chmod 2775 /var/www
find /var/www -type d -exec chmod 2775 {} \;
find /var/www -type f -exec chmod 0664 {} \;

# 8. Create Auto-Remediation Script to Synchronize Database URLs with ALB DNS
cat >> /home/ec2-user/update_wp_ip.sh << 'EOF'
#!/bin/bash
source <(php -r 'require("/var/www/html/wp-config.php"); echo("DB_NAME=".DB_NAME."; DB_USER=".DB_USER."; DB_PASSWORD=".DB_PASSWORD."; DB_HOST=".DB_HOST); ')
SQL_COMMAND="mysql -u $DB_USER -h $DB_HOST -p$DB_PASSWORD $DB_NAME -e"
OLD_URL=$(mysql -u $DB_USER -h $DB_HOST -p$DB_PASSWORD $DB_NAME -e 'select option_value from wp_options where option_name = "siteurl";' | grep http)

ALBDNSNAME=$(aws ssm get-parameters --region us-east-1 --names /A4L/Wordpress/ALBDNSNAME --query Parameters[0].Value | sed -e 's/^"//' -e 's/"$//')

if [ -n "$OLD_URL" ] && [ -n "$ALBDNSNAME" ]; then
  $SQL_COMMAND "UPDATE wp_options SET option_value = replace(option_value, '$OLD_URL', 'http://$ALBDNSNAME') WHERE option_name = 'home' OR option_name = 'siteurl';"
  $SQL_COMMAND "UPDATE wp_posts SET guid = replace(guid, '$OLD_URL','http://$ALBDNSNAME');"
  $SQL_COMMAND "UPDATE wp_posts SET post_content = replace(post_content, '$OLD_URL', 'http://$ALBDNSNAME');"
  $SQL_COMMAND "UPDATE wp_postmeta SET meta_value = replace(meta_value,'$OLD_URL','http://$ALBDNSNAME');"
fi
EOF

# 9. Configure Startup Execution & Run Immediate Sync
chmod 755 /home/ec2-user/update_wp_ip.sh
echo "/home/ec2-user/update_wp_ip.sh" >> /etc/rc.local
chmod +x /etc/rc.d/rc.local
/home/ec2-user/update_wp_ip.sh