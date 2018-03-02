#!/bin/bash
# SYNOPSIS:     Prepares an On-Premises CentOS 7.x image for Azure
# DESCRIPTION:  This shell script will update network, interface and repo configuration files, modify the boot kernel line, install the Windows Azure Agent on a Linux CentOS 7+ system
#               and deprovision the VM as a specilized image.
# EXAMPLE:      bash New-AzureRmLinuxCentOsOnPremImage.sh
# ARGUMENTS:    None
# OUTPUTS:      A *.vhd, fixed disk, generation 1 VM file that can be uploaded to an Azure storage blob container to be deployed as a specialized VM using managed disk.
# REQUIREMENTS: See references.
# AUTHOR:       Preston K. Parsard
# REFERENCES: 
#   http://www.scalearc.com/blog/2014/4/12/how-to-prepare-centos-rhel-environments-for-azure
#   https://docs.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-centos?toc=%2Fazure%2Fvirtual-machines%2Flinux%2Ftoc.json#centos-70

# Preserve original configuration files that will be updated
tmpBakDir="/var/tmp/backupDir"
kernelBootLine="/etc/default/grub"
# Windows azure agent configuration and library files.
waaCfg="/etc/waagent.conf"
waaLib="/var/lib/waagent"
# udev rules
netGenRulesCfg="/etc/udev/rules.d/75-persistent-net-generator.rules"
netGenRulesLib="/lib/udev/rules.d/75-persistent-net-generator.rules"
# 
grubConfig="/boot/grub2/grub.cfg"

# Create an associative array for the various configuration files
declare -A configFiles
configFiles=(
    ["network"]="/etc/sysconfig/network"
    ["interface"]="/etc/sysconfig/network-scripts/ifcfg-eth0"
    ["repo"]="/etc/yum.repos.d/CentOS-Base.repo"
) # end array

function preserveOriginalConfigFiles ()
{
    #  https://stackoverflow.com/questions/1494178/how-to-define-hash-tables-in-bash
    mkdir $tmpBakDir
    # "${!configFiles[@]}" expands values in the associative array
    for configFile in "${!configFiles[@]}"; do
        cp "${configFiles[$configFile]}" $tmpBakDir
    done # end for
} #end function
#NETWORK PREP
function prepareInterface ()
{
    #setup network file
    echo "NETWORKING=yes" > "${configFiles["network"]}"
    echo "HOSTNAME=localhost.localdomain" >> "${configFiles["network"]}"
} # end function

function prepareNetwork ()
{
    #Create new ifcfg-eth0 file
    echo "DEVICE=eth0" > "${configFiles["interface"]}"
    echo "ONBOOT=yes" >> "${configFiles["interface"]}"
    echo "BOOTPROTO=dhcp" >> "${configFiles["interface"]}"
    echo "DHCP=yes" >> "${configFiles["interface"]}"
    echo "TYPE=Ethernet" >> "${configFiles["interface"]}"
    echo "USERCTL=no" >> "${configFiles["interface"]}"
    echo "PEERDNS=yes" >> "${configFiles["interface"]}"
    echo "IPV6INIT=no" >> "${configFiles["interface"]}"
    echo "NM_CONTROLLED=no" >> "${configFiles["interface"]}"
    # https://serverfault.com/questions/425882/ubuntu-disable-udevs-persistent-net-generator-rules
    # Modify udev rules to avoid generating static rules, which may cause problems when cloning VMs
    sudo ln -s /dev/null $netGenRules
    # Turn on network manager on boot
    # chkconfig NetworkManager on
} # end function

#apply yum changes
function updateRepos ()
{
#Modify default repo
cat > "${configFiles["repo"]}" << EOF
[openlogic]
name=CentOS-$releasever - openlogic packages for $basearch
baseurl=http://olcentgbl.trafficmanager.net/openlogic/$releasever/openlogic/$basearch/
enabled=1
gpgcheck=0

[base]
name=CentOS-$releasever - Base
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=os&infra=$infra
baseurl=http://olcentgbl.trafficmanager.net/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#released updates
[updates]
name=CentOS-$releasever - Updates
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=updates&infra=$infra
baseurl=http://olcentgbl.trafficmanager.net/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that may be useful
[extras]
name=CentOS-$releasever - Extras
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=extras&infra=$infra
baseurl=http://olcentgbl.trafficmanager.net/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-$releasever - Plus
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=centosplus&infra=$infra
baseurl=http://olcentgbl.trafficmanager.net/centos/$releasever/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF

# Cache packages
echo "http_caching=packages" >> /etc/yum.conf

# Clear yum metadata 
sudo yum clean all
# Free up space taken by orphaned data from disabled or removed repos (-rf = recursive, force)
sudo rm -rf /var/cache/yum
# Update packages
sudo yum -y update

# https://access.redhat.com/solutions/10185
# echo "exclude=kernel*" >> /etc/yum.conf
# sed -i.bak 's/^enabled=1/enabled=0/' /etc/yum/pluginconf.d/fastestmirror.conf
yum --disableexcludes=all install kernel -y
} ##end yum changes

# Install additional AZURE components
function updateKernelBootLine ()
{
    # https://superuser.com/questions/781300/searching-for-grub-configuration-file-in-centos-7
    # Apply 5 second boot delay, redirect boot diagnostics to ttyS0 for logging.
    sed -i.bak1 '/kernel/ s/$/ console=ttyS0 earlyprintk=ttyS0 rootdelay=300 net.ifnames=0/' $kernelBootLine
    # Avoid reducing VM available memory by >= 128MB
    sed -i.bak2 '/crashkernel=auto/d' $kernelBootLine
    # Disable graphical and quiet boot, since logs will be sent to serial port tty0 in cloud environment
    sed -i.bak3 '/rhgb quiet/d' $kernelBootLine
    # Rebuild grub configuration
    sudo grub2-mkconfig -o $grubConfig
} # end function

function installAzureLinuxAgent ()
{
    # Install Azure Linux Agent and dependencies
    sudo yum -y install python-pyasn1 WALinuxAgent
    # Enable Agent
    sudo systemctl enable waagent
    # yum install WALinuxAgent -y
    # Format resource disk
    sed -i.bak4 's/ResourceDisk.Format=n/ResourceDisk.Format=y/' $waaCfg
    # Enable swap space on resource disk
    sed -i.bak4 's/ResourceDisk.EnableSwap=n/ResourceDisk.EnableSwap=y/' $waaCfg
    # Set swap size for resource disk
    sed -i.bak5 's/ResourceDisk.SwapSizeMB=0/ResourceDisk.SwapSizeMB=8192/' $waaCfg
    mkdir $waaLib
    mv $netGenRulesLib $waaLib
    mv $netGenRulesCfg $waaLib
    chkconfig NetworkManager on
} # end fucntion

function deprovisionVM
{
    # This will make sure that any iptables rules added do not get in the way of the setup process.
    chkconfig iptables off
    sudo waagent -force -deprovision
    export HISTSIZE=0
} ## end function

## START
preserveOriginalConfigFiles
prepareInterface
prepareNetwork
updateKernelBootLine
installAzureLinuxAgent
updateRepos
deprovisionVM
echo "Azure provisioning complete please shutdown the VM"
exit
poweroff