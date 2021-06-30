#!/bin/bash

# This script requires privilege users to execute.
#
# If pre-check is not skipped, checks prerequisites for installing and running
# tet-sensor on Linux hosts.
#
# If all prerequisites are met and installation succeeds, the script exits
# with 0. Otherwise it terminates with a non-zero exit code for the first error
# faced during execution.
#
# The failure message is written to a logfile if passed, stdout otherwise.
# Pre-check can skip IPv6 test by passing the --skip-ipv6 flag.
#
# Exit code - Reason:
# 255 - root was not used to execute the script
# 240 - invalid parameters are detected
# 239 - installation failed
# 238 - saving zip file failed
# 237 - sensor upgrade failed
# 236 - unsupported proxy
#   1 - pre-check: IPv6 is not configured or disabled
#   2 - pre-check: su is not operational
#   3 - pre-check: curl is missing
#   4 - pre-check: curl/libcurl compatibility test failed
#   5 - pre-check: /tmp is not writable
#   6 - pre-check: ${BASE_DIR}/${TET_SDIR} cannot be created
#   7 - pre-check: ip6tables missing or needed kernel modules not loadable
#   8 - pre-check: package missing

# Do not trust system's PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_VERSION="3.5.1.17"
LOG_FILE=
CL_HTTPS_PROXY=""
PROXY_ARGS=
NO_PROXY=0
SKIP_PRECHECK=
PRECHECK_ONLY=0
CHECK_HOST_VERSION_RC=0
NO_INSTALL=0
DISTRO=
VERSION=
SENSOR_VERSION=
SENSOR_ZIP_FILE=
SAVE_ZIP_FILE=
CLEANUP=
KEEP_CERT=
LIST_VERSION="False"
FORCE_UPGRADE=
UUID_FILE=
BASE_DIR=/usr/local
TET_SDIR=tet
ACT_PREFIX=
RELOC=
LOGBDIR=
LOGSDIR=tet
LOG_PATH_CHANGED=
TMPLOG=
TEST_USER=nobody
UNPRIVILEGED_USER=
# Sensor type is chosen by users on UI
SENSOR_TYPE="enforcer"
# Packages used by sensor without version requirement, except rpm
SENSOR_PACKAGE_USAGE=("unzip" "sed")

function print_usage {
  echo "Usage: $0 [--pre-check] [--skip-pre-check=<option>] [--no-install] [--logfile=<filename>] [--proxy=<proxy_string>] [--no-proxy] [--help] [--version] [--sensor-version=<version_info>] [--ls] [--file=<filename>] [--save=<filename>] [--new] [--reinstall] [--unpriv-user] [--force-upgrade] [--upgrade-local] [--upgrade-by-uuid=<filename>] [--basedir=<basedir>] [--logbasedir=<logbdir>] [--visibility]"
  echo "  --pre-check: run pre-check only"
  echo "  --skip-pre-check=<option>: skip pre-installation check by given option; Valid options include 'all', 'ipv6' and 'enforcement'; e.g.: '--skip-pre-check=all' will skip all pre-installation checks; All pre-checks will be performed by default"
  echo "  --no-install: will not download and install sensor package onto the system"
  echo "  --logfile=<filename>: write the log to the file specified by <filename>"
  echo "  --proxy=<proxy_string>: set the value of CL_HTTPS_PROXY, the string should be formatted as http://<proxy>:<port>"
  echo "  --no-proxy: bypass system wide proxy; this flag will be ignored if --proxy flag was provided"
  echo "  --help: print this usage"
  echo "  --version: print current script's version"
  echo "  --sensor-version=<version_info>: select sensor's version; e.g.: '--sensor-version=3.4.1.0'; will download the latest version by default if this flag was not provided"
  echo "  --ls: list all available sensor versions for your system (will not list pre-3.1 packages); will not download any package"
  echo "  --file=<filename>: provide local zip file to install sensor instead of downloading it from cluster"
  echo "  --save=<filename>: download and save zip file as <filename>"
  echo "  --new: remove any previous installed sensor; previous sensor identity has to be removed from cluster in order for the new registration to succeed"
  echo "  --reinstall: reinstall sensor and retain the same identity with cluster; this flag has higher priority than --new"
  echo "  --unpriv-user=<username>: use <username> for unpriv processes instead of tet-sensor"
  echo "  --force-upgrade: force sensor upgrade to version given by --sensor-version flag; e.g.: '--sensor-version=3.4.1.0 --force-upgrade'; apply the latest version by default if --sensor-version flag was not provided"
  echo "  --upgrade-local: trigger local sensor upgrade to version given by --sensor-version flag: e.g.: '--sensor-version=3.4.1.0 --upgrade-local'; apply the latest version by default if --sensor-version flag was not provided"
  echo "  --upgrade-by-uuid=<filename>: trigger sensor whose uuid is listed in <filename> upgrade to version given by --sensor-version flag; e.g.: '--sensor-version=3.4.1.0 --upgrade-by-uuid=/usr/local/tet/sensor_id'; apply the latest version by default if --sensor-version flag was not provided"
  echo "  --basedir=<base_dir>: instead of using /usr/local use <base_dir> to install agent. The full path will be <base_dir>/tetration"
  echo "  --logbasedir=<log_base_dir>: instead of logging to /usr/local/tet/log use <log_base_dir>. The full path will be <log_base_dir>/tetration"
  echo "  --visibility: install deep visibility agent only; --reinstall would overwrite this flag if previous installed agent type was enforcer"
}

function print_version {
  echo "Installation script for Cisco Tetration Agent (Version: $SCRIPT_VERSION)."
  echo "Copyright (c) 2018-2021 Cisco Systems, Inc. All Rights Reserved."
}

function log {
  [ -z ${TMPLOG} ] && TMPLOG=$(mktemp)
  echo $@ >> ${TMPLOG}
  if [ -z $LOG_FILE ]; then
    echo $@
  else
    echo $@ >> $LOG_FILE
  fi
}

function printf_log {
  if [[ -z $LOG_FILE ]] ; then
    printf "$1"
  else
    printf "$1" >> $LOG_FILE
  fi
}

function fullname {
  case "$1" in
    /*) echo $1
    ;;
    ~*) echo "$HOME$(echo $1 | awk '{print substr ($0,2)}')"
    ;;
    *) echo $(pwd)/$1
    ;;
  esac
}

function centos_check_package {
  for i in "${SENSOR_PACKAGE_USAGE[@]}" ;
    do
      rpm -q $i > /dev/null
      if [ $? -ne 0 ] ; then
        log "Error: No $i installed"
        PACKAGE_MISSING=1
      fi
    done  
}

function ubuntu_check_package {
  for i in "${SENSOR_PACKAGE_USAGE[@]}" ;
    do
      dpkg -s $i > /dev/null
      if [ $? -ne 0 ] ; then
        rpm -q $i > /dev/null
        if [ $? -ne 0 ] ; then
          log "Error: No $i installed"
          PACKAGE_MISSING=1
        fi
      fi
    done  
}

# Compare two version number
# Return 0 if op = '='
# Return 1 if op = '>'
# Return 2 if op = '<'
function compare_version {
  if [ -z $1 ] ; then
    if [ -z $2 ] ; then
      return 0
    else
      return 2
    fi
  fi
  if [ -z $2 ] ; then
    return 1
  fi
  if [ $1 == $2 ] ; then
    return 0
  fi
  local IFS=".-"
  local i ver1=($1) ver2=($2)
  local ver1_first_arg ver1_second_arg ver2_first_arg ver2_second_arg
  for (( i=${#ver1[@]}; i<${#ver2[@]}; i++ )) ; do
    ver1[i]=0
  done
  for (( i=0; i<${#ver1[@]}; i++ )) ; do
    if [ -z ${ver2[i]} ] ; then
      ver2[i]=0
    fi
    ver1_first_arg=${ver1[i]//[A-Za-z]/}
    [ -z $ver1_first_arg ] && ver1_first_arg=0
    ver2_first_arg=${ver2[i]//[A-Za-z]/}
    [ -z $ver2_first_arg ] && ver2_first_arg=0
    if [ $ver1_first_arg -gt $ver2_first_arg ] ; then
      return 1
    elif [ $ver1_first_arg -lt $ver2_first_arg ] ; then
      return 2
    else
      ver1_second_arg=${ver1[i]//[0-9]/}
      [ -z $ver1_second_arg ] && ver1_second_arg=0
      ver2_second_arg=${ver2[i]//[0-9]/}
      [ -z $ver2_second_arg ] && ver2_second_arg=0
      if [ $ver1_second_arg \> $ver2_second_arg ] ; then
        return 1
      elif [ $ver1_second_arg \< $ver2_second_arg ] ; then
        return 2
      fi
    fi
  done
  return 0
}

# check if package version meets requirement
# args: package name, version, release
# e.g.: openssl, 1.0.2k, 16.el7
function check_pkg_version_rpm {
  package_version="$(rpm -qi $1 | awk -F': ' '/Version/ {print $2}' | awk -F' ' '{print $1}')"
  package_version=(${package_version[0]})
  if [ -z $package_version ] ; then
    log "Error: No $1 installed"
    return 1
  fi
  package_release="$(rpm -qi $1 | awk -F': ' '/Release/ {print $2}' | awk -F' ' '{print $1}')"
  package_release=(${package_release[0]})
  compare_version $package_version $2 
  compare_result=$?
  if [ $compare_result -eq 0 ] ; then
    compare_version "$package_release" $3
    if [ $? -eq 2 ] ; then
      log "Error: Lower version of $1 installed"
      log "$package_version-$package_release detected; $2-$3 required"
      return 1 
    fi
  elif [ $compare_result -eq 2 ] ; then
    log "Error: Lower version of $1 installed"
    log "$package_version-$package_release detected; $2-$3 required"
    return 1
  fi
  return 0
}

function check_pkg_version_dpkg {
  package_version_release="$(dpkg -s $1 | awk -F': ' '/Version/ {print $2}' | awk -F' ' '{print $1}')"
  package_version_release=(${package_version_release[0]})
  if [ -z $package_version_release ] ; then
    # also check rpm
    check_pkg_version_rpm $1 $2 $3
    [ $? -ne 0 ] && return 1
    return 0
  fi 
  package_version="${package_version_release%-*}"
  package_release="${package_version_release#*-}"
  compare_version "${package_version}" $2 
  compare_result=$?
  if [ $compare_result -eq 0 ] ; then
    compare_version "${package_release%ubuntu*}" $3
    if [ $? -eq 2 ] ; then
      log "Error: Lower version of $1 installed"
      log "$package_version-$package_release detected; $2-$3 required"
      return 1 
    fi
  elif [ $compare_result -eq 2 ] ; then
    log "Error: Lower version of $1 installed"
    log "$package_version-$package_release detected; $2-$3 required"
    return 1
  fi
  return 0
}

function pre_check {
  log ""
  log "### Testing tet-sensor prerequisites on host \"$(hostname -s)\" ($(date))"
  log "### Script version: $SCRIPT_VERSION"
  [ "$SKIP_PRECHECK" = "all" ] && log "Skip all pre-checks" && return 0

  # Used for detecting when running on Ubuntu
  PACKAGE_MISSING=
  # Check packages
  log "Detecting dependencies"
  printf_log "Checking for awk... "
  awk -W version > /dev/null 2>&1
  if [ $? -ne 0 ] ; then
    printf_log "not found\n"
    PACKAGE_MISSING=1
  else
    printf_log "yes\n"
  fi
  printf_log "Checking for flock... "
  flock -V > /dev/null 2>&1
  if [ $? -ne 0 ] ; then
    printf_log "not found\n"
    PACKAGE_MISSING=1
  else
    printf_log "yes\n"
  fi
  printf_log "Checking for lsof... "
  lsof -v > /dev/null 2>&1
  if [ $? -ne 0 ] ; then
    printf_log "not found\n"
    PACKAGE_MISSING=1
  else
    printf_log "yes\n"
  fi
  ARCH=$(uname -m)
  if [ "$ARCH" != "s390x" ] ; then
    printf_log "Checking for dmidecode... "
    dmidecode_version=$(dmidecode -V 2>/dev/null)
    if [ $? -ne 0 ] ; then
      printf_log "not found\n"
      PACKAGE_MISSING=1
    else
      printf_log "yes\n"
      printf_log "Checking whether the dmidecode version >= 2.11... "
      compare_version $dmidecode_version "2.11"
      if [ $? -eq 2 ] ; then
        printf_log "no; ${dmidecode_version} detected\n"
        log "Error: Lower version of dmidecode installed"
        PACKAGE_MISSING=1
      else
        printf_log "yes; ${dmidecode_version} detected\n"
      fi
    fi
  fi
  case $DISTRO in
      RedHatEnterpriseServer | CentOS | OracleServer)
        log "Checking for openssl version"
        centos_check_package
        case $VERSION in
          5*)
            check_pkg_version_rpm "openssl" "0.9.8e" || PACKAGE_MISSING=1
            ;;
          6*)
            check_pkg_version_rpm "openssl" "1.0.1e" || PACKAGE_MISSING=1
            ;;
          7*)
            check_pkg_version_rpm "openssl" "1.0.1e" || PACKAGE_MISSING=1
            ;;
          8*)
            check_pkg_version_rpm "openssl" "1.1.1" || PACKAGE_MISSING=1
            ;;
        esac
        if [ "$SENSOR_TYPE" = "enforcer" ] && [ "$SKIP_PRECHECK" != "enforcement" ] ; then
          log "Checking for ipset version"
          check_pkg_version_rpm "ipset" "6.11" "4" || PACKAGE_MISSING=1
          log "Checking for iptables version"
          check_pkg_version_rpm "iptables" "1.4.7" "16" || PACKAGE_MISSING=1
        fi
      ;;
      SUSELinuxEnterpriseServer)
        log "Checking for openssl version"
        centos_check_package
        case $VERSION in
          11*)
            check_pkg_version_rpm "openssl" "0.9.8j" || PACKAGE_MISSING=1
            ;;
          12*)
            check_pkg_version_rpm "openssl" "1.0.1i" || PACKAGE_MISSING=1
            ;;
          15*)
            check_pkg_version_rpm "openssl" "1.1.0h" || PACKAGE_MISSING=1
        esac
        if [ "$SENSOR_TYPE" = "enforcer" ] && [ "$SKIP_PRECHECKK" != "enforcement" ]; then
          log "Checking for ipset version"
          check_pkg_version_rpm "ipset" "6.11" "4" || PACKAGE_MISSING=1
          log "Checking for iptables version"
          check_pkg_version_rpm "iptables" "1.4.6" "2.11.4" || PACKAGE_MISSING=1
        fi
      ;;
      Ubuntu)
        log "Checking for openssl version"
        ubuntu_check_package
        case $VERSION in
          14*)
            check_pkg_version_dpkg "openssl" "1.0.1f" || PACKAGE_MISSING=1
            ;;
          16*)
            check_pkg_version_dpkg "openssl" "1.0.2g" || PACKAGE_MISSING=1
            ;;
          18*)
            check_pkg_version_dpkg "openssl" "1.1.0" || PACKAGE_MISSING=1
            ;;
          20*)
            check_pkg_version_dpkg "openssl" "1.1.1" || PACKAGE_MISSING=1
            ;;
        esac
        if [ "$SENSOR_TYPE" = "enforcer" ] && [ "$SKIP_PRECHECK" != "enforcement" ]; then
          log "Checking for ipset version"
          check_pkg_version_dpkg "ipset" "6.11" "4" || PACKAGE_MISSING=1
          log "Checking for iptables version"
          check_pkg_version_dpkg "iptables" "1.4.7" "16" || PACKAGE_MISSING=1
        fi
      ;;
      AmazonLinux)
        log "Checking for openssl version"
        centos_check_package
        check_pkg_version_rpm "openssl" "1.0.2k" || PACKAGE_MISSING=1
        if [ "$SENSOR_TYPE" = "enforcer" ] && [ "$SKIP_PRECHECKK" != "enforcement" ]; then
          # since Amazon Linux 2 is pretty recent, we don't check for minimum version
          printf_log "Checking for ipset... "
          ipset -v > /dev/null 2>&1
          if [ $? -ne 0 ] ; then
            printf_log "not found\n"
            PACKAGE_MISSING=1
          else
            printf_log "yes\n"
          fi
          printf_log "Checking for iptables... "
          iptables -V > /dev/null 2>&1
          if [ $? -ne 0 ] ; then
            printf_log "not found\n"
            PACKAGE_MISSING=1
          else
            printf_log "yes\n"
          fi
        fi
      ;;
  esac
  if [ ! -z $PACKAGE_MISSING ] ; then
    return 8
  fi

  # detect whether IPv6 is enabled
  if [ "$SENSOR_TYPE" = "enforcer" ] && [ "$SKIP_PRECHECK" != "enforcement" ] && [ "$SKIP_PRECHECK" != "ipv6" ]; then
    printf_log "Checking whether IPv6 is enabled... "
    if [ ! -e /proc/sys/net/ipv6 ]; then printf_log "no\n"; log "Error: IPv6 is not configured"; return 1; fi
    v=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    ret=$?
    if [ $ret -ne 0 ]; then printf_log "no\n"; log "Error: Failed to verify if IPv6 is enabled: ($ret)"; return 1; fi
    if [ $v = 1 ]; then printf_log "no\n"; log "Error: IPv6 is disabled"; return 1; fi
    printf_log "yes\n"
    printf_log "Checking for ip6tables... "
    output=$(which ip6tables 2>&1)
    if [ $? -ne 0 ]; then
      printf_log "not found\n"
      return 7
    else
      printf_log "${output}\n"
    fi
    printf_log "Checking whether the ip6tables works... "
    ip6tables -nvL > /dev/null 2>&1
    if [ $? -ne 0 ]; then
      printf_log "no\n"
      log "Error: ip6tables command is not functional (check kernel modules)"
      return 7
    fi
    printf_log "yes\n"
  fi

  printf_log "Checking for su support... "
  # detect whether su could be invoked
  (su ${TEST_USER} -s /bin/bash -c date >> /dev/null) &
  PID=$!
  sleep 6; kill -9 $PID 2> /dev/null
  wait $PID
  if [ $? -ne 0 ]; then
    printf_log "no\n"
    log "Error: su failed to return within specified time"
    return 2
  fi
  printf_log "yes\n"

  printf_log "Checking for curl... "
  output=$(which curl 2>&1)
  if [ $? -ne 0 ]; then
    printf_log "not found\n"
    return 3
  fi
  printf_log "${output}\n"
  printf_log "Checking whether the curl version matches the libcurl version... "
  CURL_VER=$(curl --version | head -1 | awk '{print $2}')
  LIBCURL_VER=$(curl --version |head -1 | awk -F "libcurl/" '{print $2}' | awk '{print $1}')
  if [ ${CURL_VER} != ${LIBCURL_VER} ] ; then
    printf_log "no; curl ${CURL_VER} and libcurl ${LIBCURL_VER} detected\n"
    log "Error: curl $CURL_VER and libcurl $LIBCURL_VER not matching. This could be an issue."
    return 4
  fi
  printf_log "yes; ${CURL_VER} detected\n"

  printf_log "Checking for tmpfile support... "
  RAND_NUM=$RANDOM
  su ${TEST_USER} -s /bin/bash -c "echo $RAND_NUM > /tmp/$RAND_NUM"
  ret=$?
  if [ $ret -ne 0 ]; then
    printf_log "no\n"
    log "Error: Cannot create file in /tmp/: ($ret)"
    return 5
  fi
  rm -rf /tmp/$RAND_NUM
  printf_log "yes\n"

  printf_log "Checking for ${BASE_DIR}/${TET_SDIR}... "
  if [ ! -e  ${BASE_DIR}/${TET_SDIR}/ ]; then
    mkdir -p ${BASE_DIR}/${TET_SDIR}
    ret=$?
    if [ $ret -ne 0 ]; then
      printf_log "no\n"
      log "Error: Cannot create ${BASE_DIR}/${TET_SDIR}: ($ret)"
      return 6
    fi
    rmdir ${BASE_DIR}/${TET_SDIR}
    printf_log "yes\n"
  else
    printf_log "yes\n"
    # check the expected processes are running
    t=$(ps -e | grep tet-engine)
    te1=$(echo $t | awk '{ print $4 }')
    te2=$(echo $t | awk '{ print $8 }')
    t=$(ps -e | grep tet-sensor)
    ts1=$(echo $t | awk '{ print $4 }')
    ts2=$(echo $t | awk '{ print $8 }')
    if [ "$te1" = "tet-engine" ] && [ "$te2" = "tet-engine" ] && [ "$ts1" = "tet-sensor" ] && [ "$ts2" = "tet-sensor" ] ; then
      log "${BASE_DIR}/${TET_SDIR} already present. Expected tet-engine and tet-sensor instances found"
    else
      log "${BASE_DIR}/${TET_SDIR} already present. Expected tet-engine and tet-sensor instances NOT found"
    fi
  fi

  log "### Pre-check Passed"
  return 0
}

function check_host_version {
   # Check for Oracle Linux
   # Older version does not have /etc/os-release
   # Also the /etc/redhat-release is showing Red Hat Linux version
   # So we need to check the file /etc/oracle-release first
   # output looks like this "Oracle Linux Server release 6.10"
   if [ -e /etc/oracle-release ] ; then
      local releasestring=$(cat /etc/redhat-release | grep -e "^Oracle")
      DISTRO=$(cat /etc/oracle-release | awk '{print $1$3}')
      VERSION=$(cat /etc/oracle-release | awk -F 'release ' '{print $2}' | awk '{print $1}')
      [ "$DISTRO" = "OracleServer" ] && return 0
   fi

   # SuSE has consistent version in the specific SuSE-release file, dropped for SLES15
   if [ -e /etc/SuSE-release ] ; then
       DISTRO=$(cat /etc/SuSE-release | head -1 | awk '{print $1$2$3$4}')
       VERSION=$(cat /etc/SuSE-release | grep 'VERSION' | awk -F '=' '{print $2}' | awk '{print $1}')
       VERSION=$VERSION.$(cat /etc/SuSE-release | grep 'PATCHLEVEL' | awk -F '=' '{print $2}' | awk '{print $1}')
       [ "$DISTRO" = "SUSELinuxEnterpriseServer" ] && return 0
   fi

   # Check for redhat/centos
   # In CentOS, string looks like this: "CentOS release 6.x (Final)"
   # CentOS Linux release 7.2.1511 (Core)
   # But in RHEL, string looks like this: "Red Hat Enterprise Linux Server release 6.x (Santiago)"
   # Or "Red Hat Enterprise Linux release 8.0 (Ootpa)"
   # But there might be lines with comments

   if [ -e /etc/redhat-release ] ; then
       local releasestring=$(cat /etc/redhat-release | grep -e "^Cent" -e "^Red")
       if [ $? -eq 0 ] ; then
	   DISTRO=$(echo $releasestring | awk '{print $1}')
	   [ $DISTRO = "Red" ] && DISTRO="RedHatEnterpriseServer"
	   VERSION=$(echo $releasestring | awk -F 'release ' '{print $2}' | awk '{print $1}' | awk -F "." '{printf "%s.%s", $1, $2}')
	   [ "$VERSION" = "5." ] && VERSION="5.0"
	   [ "$(echo $VERSION | head -c 1)" = "5" ] && [ "$SENSOR_TYPE" = "enforcer" ] && echo "Warning: Enforcer not supported on $DISTRO.$VERSION" && SENSOR_TYPE="sensor"
	   return 0
       fi
   fi

   # Ubuntu and Debian have os-release which is a script
   if [ -e /etc/os-release ] ; then
      . /etc/os-release
      DISTRO=$NAME
      VERSION=$VERSION_ID
      if [[ $DISTRO == Debian* ]] ; then
        DISTRO=$(echo $DISTRO | awk '{print $1}')
        return 0
      fi
      [ "$VERSION" = "12.04" ] && [ "$SENSOR_TYPE" = "enforcer" ] && echo "Warning: Enforcer not supported on $DISTRO.$VERSION" && SENSOR_TYPE="sensor"
      if [ "$NAME" = "SLES" ] ; then
        DISTRO="SUSELinuxEnterpriseServer"
        if [ "$VERSION" = "15" ] ; then
            VERSION=15.0
        fi
      fi
      if [ "$NAME" = "Amazon Linux" ] ; then
        DISTRO="AmazonLinux"
      fi
      return 0
   fi

   # Unknown OS/Version
   DISTRO="Unknown"
   VERSION=`uname -a`
   return 1
}

function check_basedir_for_installed_sensor {
  ACT_PREFIX=$(cat /etc/systemd/system/tet-sensor.service 2>/dev/null | grep ExecStartPre | grep fetch_sensor_id.sh | awk -F' ' '{print $2}')
  [ "$ACT_PREFIX" = "" ] && ACT_PREFIX=$(cat /etc/init.d/tet-sensor 2>/dev/null | grep fetch_sensor_id | awk '{print $1}' | xargs dirname 2>/dev/null)
  [ "$ACT_PREFIX" = "" ] && ACT_PREFIX=$(cat /etc/init/tet-sensor.conf 2>/dev/null | grep fetch_sensor_id | awk '{print $1}' | xargs dirname 2>/dev/null)
  local tetdir=$(echo "$ACT_PREFIX" | xargs basename 2>/dev/null)
  [ ! -z $tetdir ] && [ $tetdir != "tet" ] && [ $tetdir != "tetration" ] && ACT_PREFIX=""
}

# Check if old binaries already exist or sensor registered in rpm db
function check_sensor_exists {
  if dpkg -s tet-sensor 2>/dev/null | grep Status: | grep installed ; then
    log "Sensor found in dpkg db"
    return 1
  fi
  if [ ! -z "$(rpm -qa tet-sensor 2>/dev/null)" ] || [ ! -z "$(rpm -qa tet-sensor-site 2>/dev/null)" ] ; then
    log "Sensor found in rpm db"
    return 1
  fi
  log "Sensor not found"
  return 0
}

function preinstall_setup {
  mkdir -p ${BASE_DIR}/${TET_SDIR} && chmod 750 ${BASE_DIR}/${TET_SDIR}
  for subdir in ${BASE_DIR}/${TET_SDIR}/chroot ${BASE_DIR}/${TET_SDIR}/conf ${BASE_DIR}/${TET_SDIR}/cert ; do
    mkdir -p $subdir && chmod 755 $subdir
  done
  if [ ! -z $KEEP_CERT ] ; then
    cp ${TMP_DIR}/client.cert ${BASE_DIR}/${TET_SDIR}/cert/client.cert
    cp ${TMP_DIR}/client.key ${BASE_DIR}/${TET_SDIR}/cert/client.key
    cp ${TMP_DIR}/.sensor_uuid ${BASE_DIR}/${TET_SIDR}/.sensor_uuid
    [ -d "${TMP_DIR}/backup" ] && cp -R ${TMP_DIR}/backup ${BASE_DIR}/${TET_SDIR}/
  fi
  if [ "${LOGBDIR}" != "${BASE_DIR}" ] ; then
      mkdir -p ${LOGBDIR}/${LOGSDIR}
      ln -sf ${LOGBDIR}/${LOGSDIR} ${BASE_DIR}/${TET_SDIR}/log
  fi

  rm -f ${BASE_DIR}/${TET_SDIR}/site.cfg
  [ -e $TMP_DIR/sensor.cfg ] && install -m 644 $TMP_DIR/sensor.cfg ${BASE_DIR}/${TET_SDIR}/conf/.sensor_config
  [ -e $TMP_DIR/enforcer.cfg ] && install -m 644 $TMP_DIR/enforcer.cfg ${BASE_DIR}/${TET_SDIR}/conf/enforcer.cfg
  install -m 644 $TMP_DIR/ta_sensor_ca.pem ${BASE_DIR}/${TET_SDIR}/cert/ca.cert
  # sensor rpm is supposed to check this file and start enforcer service
  sh -c "echo -n "$SENSOR_TYPE" > ${BASE_DIR}/${TET_SDIR}/sensor_type"
  # copy user.cfg file if the old file does not exist
  test -f ${BASE_DIR}/${TET_SDIR}/user.cfg
  [ $? -ne 0 ] && [ -e $TMP_DIR/tet.user.cfg ] && install -m 644 $TMP_DIR/tet.user.cfg ${BASE_DIR}/${TET_SDIR}/user.cfg
}

function perform_install {
  log ""
  log "### Installing tet-sensor on host \"$(hostname -s)\" ($(date))"
  if [ -z "$DISTRO" ] ; then
    if [ -e /etc/os-release ]; then
      . /etc/os-release
      DISTRO=$NAME
    fi
  fi

  # Create a random folder in /tmp, assuming it's writable (pre-check done)
  TMP_DIR=$(mktemp -d /tmp/tet.XXXXXX)
  log "Created temporary directory $TMP_DIR"

  if [ ! -z $KEEP_CERT ] ; then
    [ -z "$ACT_PREFIX" ] && log "Failed to locate installed sensor" && return 1
    if [ -e ${ACT_PREFIX}/cert/client.cert ] && [ -e ${ACT_PREFIX}/cert/client.key ] ; then
      cp ${ACT_PREFIX}/cert/client.cert ${TMP_DIR}/client.cert
      cp ${ACT_PREFIX}/cert/client.key ${TMP_DIR}/client.key
      cp ${ACT_PREFIX}/.sensor_uuid ${TMP_DIR}/.sensor_uuid
      [ -d "${ACT_PREFIX}/backup" ] && cp -R ${ACT_PREFIX}/backup ${TMP_DIR}/
    else
      log "Failed to locate client cert and key" && return 1
    fi
  fi
  if [ ! -z $CLEANUP ] ; then
    log "cleaning up before installation"
    if dpkg -s tet-sensor 2>/dev/null | grep Status: | grep installed ; then
      log "Clean up Debian"
      dpkg --purge --debug=3 tet-sensor
    else
      if [ ! -z "$(rpm -qa tet-sensor)" ] ; then 
        rpm -e tet-sensor
      fi
      if [ ! -z "$(rpm -qa tet-sensor-site)" ] ; then
        rpm -e tet-sensor-site
      fi
    fi
    [ ! -z $ACT_PREFIX ] && rm -rf $ACT_PREFIX
  fi
  [ $NO_INSTALL -eq 2 ] && !(check_sensor_exists) && return 1

  EXEC_DIR=$(pwd)
  log "Execution directory $EXEC_DIR"
  cd $TMP_DIR

cat << EOF > tet.user.cfg
ACTIVATION_KEY=12bc133e81a88c03e36639456397997d73516d2a
HTTPS_PROXY=$CL_HTTPS_PROXY
INSTALLATION_ID=mario_ruiz_20210628022131
UNPRIVILEGED_USER=${UNPRIVILEGED_USER}
EOF

cat << EOF > ta_sensor_ca.pem
-----BEGIN CERTIFICATE-----
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
nPvntjQYhEppo67v56xn3NIsmqcU
-----END CERTIFICATE-----

EOF

  # Decide which key to used for validation of whether the package is properly signed.
  # If the key already exist we won't overwrite it.
  if [[ $DISTRO == Debian* ]] || [[ $DISTRO == Ubuntu* ]] ; then
    if [ ! -e sensor-openssl.key ] ; then

      DEV_SENSOR=false
      if [ "$DEV_SENSOR" = true ] ; then

      # This is the dev public sensor signing key.
cat << EOF > sensor-openssl.key
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwfmlC4IDIz/xrWI/J9Vc
CeBqk7xokNkZMux6qh1698B3EHwneVRlz77y095ADkmC4kwkDZCkDuuMTtli7yta
jQlm0RxddlSOVjn/sxaYgiRN/kXxbfTvMXLfdoRmoLXw7tuNEpu04Xx9dNo9BnBV
G4AU5KWk2wuny1AvQX4gw803t0TuJ4FFUhUz1J0lq80CRyqotvLUOrhNEyCrU1DL
b2gVV0NwurKyIJai/UmA1GEauGD5NNpOLBtXumuaJQQduwg3yGJIPcOzuzFDVl5S
UzHtM0LI0Fyxv3p6kZm2ATHuEHnl+P5cjqMObWW2z+HWl+FrzvVpRoy8372PUpiG
J1AJHIJd+w829cJXcV1ZZN0BiXZ8ZCH3jj7vI16yjk0uWczg4I+9IQeKqI4gQl9y
KwrFWXs8iJUJuu33txQ+NxvjvYamg0fysQSEF4GzEaIxzLrHQhb+ySwH3jHEu9cN
39rmLiuhQuI8R8eLU4YEdM2eteT/gp1WUXSeOTcvFzTZ1DCmH69ISus4ffrjM9WZ
I1CzaI7lFXu6dPe9WKf+/F+sEFLBJVPcCe0kUaAOG12GMLcnpzK0cdDTthbVMfti
0WKVLS8Sl+XFeT2HIc1XTdaZlpZPyiNucS3HhWRyFkc1L0yMB99DJ5hdAjY9RX2r
2f2yasVDRVHHkeobyuB4dL8CAwEAAQ==
-----END PUBLIC KEY-----
EOF

      else

      # This is the prod public sensor signing key.
cat << EOF > sensor-openssl.key
-----BEGIN PUBLIC KEY-----
MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAxld6WKezNhQk5FJA0oHP
pPDCReVqb/VOZRBaS7Ag84Xf/iFhE0SBz8rbq1dFrdkif7fQqa59tijUV4d8zGC2
1w8HqP6IIUN0cDzEpNH5ouKAdbEVKd9FomS5k0i3ziyarnXGj5hW8EssGXBhBksy
nJoO/TcRyCfyKjjkWoM1XPck6fZWuWE7NZ5gMPUD4K4BlX/ljE5VOjlK/i+Uru80
LSneAd31i1IzK6s0Cl/jyZBDkLqrZVBDQZfJ65BxmrATdNiVoU2PEytDL3/znuv3
C0m2lUjV7paS9EB8kUmTdGSuSf9P7UqNxAIM84a9TiPmxVZz6xz3N36xHorvr6ZD
bnSTfJSGroXebo9kTZiFj6DRDyy1d5YpfXKHxXAHgiTiFdsGHtVpYyNHkw5o5eXq
ih/FP5eJia6qMthkO7YZhVLv4+wXd9xnynxAmeehaYS5FT6HIQ3Yy5TNnwRAl2a5
4zM9OBbuqEdyfRPGRjKW5ynqpxOFeMO2sc+u58Hi02/f524+9yV9z3zFQjLrD89e
TKagpJos9uftsfJI9gK0rgQhvQ742LBVpRZJXnorQ6hTw1osjvO5vknqJKhsaRlH
odNngaNtqvj+sR987bzEsZWvTgtArZkWgqnCgV55V+ccIkFsX59axs+I1Ojxz+R/
toNHCYRGERBInAEUn0xkteMCASM=
-----END PUBLIC KEY-----
EOF

      fi
    fi
  fi
  if [[ $DISTRO != Debian* ]] ; then
    if [ ! -e sensor-gpg.key ] ; then
        DEV_SENSOR=false
        if [ "$DEV_SENSOR" = true ] ; then

          # This is the dev public sensor signing key.
cat << EOF > sensor-gpg.key
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.11 (GNU/Linux)

mQENBFbECa0BCADQV84MekXnIZB7lKBBn+Hfq6MTgl/0SIZCSQaiznXZ1oKwcIIq
izU4kE/rY8XoOZdIataFcMYycH4U5NkAx11DdvSH6hrIG9BmIlcZKw92oE/YLgZP
xCUug2UDAI8QLZawPBttwal/LU9oeuKHeF8K4iIlmq3Z38KLhGPsD6Tvhl2/bAez
xyp2cFRrKcvYdaKIA6aBHHLSpfo+wXUXHtI+vyBd6Hp+5BrqbwZvFT7bnD7csOAx
hWs9MX2wm4ANmlTWed00pEMjS5iOTwzPeAlQlyleLXEjtXzoCEuq+9ufEirvDVqb
JQeL/pxGYN80w625h4EOJ92/L7XTVUwlPJnxABEBAAG0MlNlbnNvciBEZXYgS2V5
IDxzZW5zb3ItZGV2QHRldHJhdGlvbmFuYWx5dGljcy5jb20+iQE+BBMBAgAoBQJW
xAmtAhsDBQkJZgGABgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAKCRAlscFprx/C
b3YHB/90K7lK5wwo+H+EccA9JQ19xnFK78M8UGgGj6QT2rcf1NJgTD2FXlpIEVGZ
yf3UBhyTdhlM0RsyIE4S65XrorgulM4Hzy94/y0kSRBJfnnFBKI1uNJVRupY4Y/9
WJrV7y1JN0ubFpjBdHKrKqq9822XSLVF7F3ZzLmwRMMLtFDi+leHnFCZ0OY4z7Yv
wd1XGZNhaApryQUZbjSIOgiTQCvTN+P0EEo73sm0rUxnpvQapzbWUnAWAoCI4vbb
q57mUGQZ7tYEeooEiTjk9xyU8PA0cRVarMbMNoXZtvu+xW0ipYRx6zh7Od5enGFP
LxrgudPMvK79Z22e+SZ7GiwFO5ON
=jaK+
-----END PGP PUBLIC KEY BLOCK-----
EOF

        else

          # This is the prod public sensor signing key.
cat << EOF > sensor-gpg.key
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2.0.14 (GNU/Linux)

mQENBFYVKHUBCACv6ZaWxa0/VptX9YJvnLEZvPSCV7idmbi0K911bYCY7OTpCzl1
tfDJO1SLiLeyT88Rq8PYzjY3fZqtdn3l9HTGkKqLbHOFV3qWgCau2I3SXEiIIis+
TL50zTXnF05kUKdYWXIjWgM8oD8GHQA+oWgyKWFZgA32rmcwIshndrP406U1b31N
sdo0AMbfa2nY5CHj31Cyg2/t53NOOCcVasCZ1Jx5MEkNmyNAUDtG1HbeTCjhG+Qn
ul4ugICRKiPtGsGlAhV+cI8sX9GUgepp0AzCaCEVmudwIuAT5+s0NGXqKaLTqBPV
t1fWk4U9Nw1BKd/AtFTy9u1uju0TVsOwO6XrABEBAAG0NlRldHJhdGlvbiBTZW5z
b3IgPHNlbnNvci1hZG1pbkB0ZXRyYXRpb25hbmFseXRpY3MuY29tPokBPgQTAQIA
KAUCVhUodQIbAwUJEswDAAYLCQgHAwIGFQgCCQoLBBYCAwECHgECF4AACgkQkuMZ
7s+YSL4Q1AgAmav2IsXsUgXu5rzBeTXD+0kuwX36MJg8g4/4nwxla2bQMmhzCuC8
436FX5h3eR3Mipviah3xmw8yolfYmBNmINFfl4mAbXa8WAPatdD0fL1AXdRGre1c
EI9kUIR0WfUIVURkZJPNsdn6Jass3ZUhw51v9o0gEi5GPFtHCXtvZR2BIwZ89mUK
0qS1pL5w0zezZAyB7A6tJFy+bI1rYX833oNsTMIUT+hMcpCVIWTWbUytxHb8SGmN
84Bk9j+nyofYOyrSgNLCbZe01YFNbjH9u0f/DvGjRE8km32z073AwSEHoq7CTnJQ
fEqigBGTJ6FXVHUQM4BFVmdknmL9LMd7lg==
=BN2J
-----END PGP PUBLIC KEY BLOCK-----
EOF

        fi
    fi
  fi
  # Donot check_host_version if we trigger sensor upgrade in backend
  if [ -z $UUID_FILE ] ; then
    # Download the package with config files
    PKG_TYPE="sensor_w_cfg"
    [ $CHECK_HOST_VERSION_RC -ne 0 ] && log "Error: Unsupported platform $DISTRO-$VERSION" && cd $EXEC_DIR && return 1
  fi

  CHK_SUM=""
  CONTENT_TYPE=""
  TS=$(date -u "+%Y-%m-%dT%H:%M:%S+0000")
  HOST="https://wsstuvok.tetrationcloud.com"
  API_KEY=460b81a9adb54e2fb904bb1629f1eaa0
  API_SECRET=a2a3f6ddcfc60d937d3bb89caa908c76b7133b11
  ARCH=$(uname -m)
  case $CL_HTTPS_PROXY in
    http:*)
      PROXY_ARGS="-x $CL_HTTPS_PROXY"
      log "$CL_HTTPS_PROXY will be used as proxy"
      ;;
    "")
      [ $NO_PROXY -eq 1 ] && PROXY_ARGS="-x \"\"" && log "will bypass proxy"
      ;;
    *)
      [ ! -z $CL_HTTPS_PROXY ] && log "proxy $CL_HTTPS_PROXY will not be used by curl"
      ;;
  esac
  if [ $LIST_VERSION = "True" ] ; then
    METHOD="GET"
    URI="/openapi/v1/sw_assets/download?pkg_type=$PKG_TYPE\&platform=$DISTRO-$VERSION\&arch=$ARCH\&list_version=$LIST_VERSION"
    URI_NO_ESC="/openapi/v1/sw_assets/download?pkg_type=$PKG_TYPE&platform=$DISTRO-$VERSION&arch=$ARCH&list_version=$LIST_VERSION"
  elif [ ! -z $UUID_FILE ] ; then
    uuid=$(head -n 1 "$UUID_FILE")
    METHOD="POST"
    URI="/sensor_config/upgrade/$uuid?sensor_version=$SENSOR_VERSION"
    URI_NO_ESC="/sensor_config/upgrade/$uuid?sensor_version=$SENSOR_VERSION"
  else # regular download
    METHOD="GET"
    URI="/openapi/v1/sw_assets/download?pkg_type=$PKG_TYPE\&platform=$DISTRO-$VERSION\&arch=$ARCH\&sensor_version=$SENSOR_VERSION"
    URI_NO_ESC="/openapi/v1/sw_assets/download?pkg_type=$PKG_TYPE&platform=$DISTRO-$VERSION&arch=$ARCH&sensor_version=$SENSOR_VERSION"
  fi
  TMP_FILE=tmp_file
  RPM_FILE=tet-sensor-$DISTRO-$VERSION.rpm
  rm -rf $TMP_FILE
  # Calculate the signature based on the params
  # <httpMethod>\n<requestURI>\n<chksumOfBody>\n<ContentType>\n<TimestampHeader>
  MSG=$(echo -n -e "$METHOD\n$URI_NO_ESC\n$CHK_SUM\n$CONTENT_TYPE\n$TS\n")
  SIG=$(echo "$MSG"| openssl dgst -sha256 -hmac $API_SECRET -binary | openssl enc -base64)
  REQ=$(echo -n "curl $PROXY_ARGS -v -X $METHOD --cacert ta_sensor_ca.pem $HOST$URI -w '%{http_code}' -o $TMP_FILE -H 'Timestamp: $TS' -H 'Content-Type: $CONTENT_TYPE' -H 'Id: $API_KEY' -H 'Authorization: $SIG'")
  if [ -z $SENSOR_ZIP_FILE ] ; then
    count=0
    until [ $count -ge 3 ]
    do
      status_code=$(sh -c "$REQ")
      curl_status=$?
      if [ $curl_status -ne 0 ] ; then
        log "Curl error: $curl_status"
        cd $EXEC_DIR
        return 1
      fi
      if [ $status_code -eq 200 ] ; then
        break
      fi
      log "Failed in request $REQ"
      echo "Status code: $status_code"
      if [ -e $TMP_FILE ] ; then
        resp_info=$(cat $TMP_FILE)
        log "Error details: ${resp_info:0:512}" # log download failure and truncate it
      fi
      count=$[$count+1]
      echo "Retry in 15 seconds..."
      sleep 15
    done
    [ $status_code -ne 200 ] && cd $EXEC_DIR && return 1
  fi
  [ ! -z $UUID_FILE ] && cd $EXEC_DIR && return 0 
  if [ $LIST_VERSION = "True" ] ; then
    if [ -e $TMP_FILE ] ; then
      local IFS=
      details=$(cat $TMP_FILE)
    fi
    echo "Available version:" && echo $details && cd $EXEC_DIR && return 0
  fi
  if [ ! -z $SENSOR_ZIP_FILE ] ; then
    [ ! -e $SENSOR_ZIP_FILE ] && echo "$SENSOR_ZIP_FILE does not exist" && log "Error: $SENSOR_ZIP_FILE does not exist" && cd $EXEC_DIR && return 1
    cp $SENSOR_ZIP_FILE $TMP_FILE
  fi
  unzip $TMP_FILE
  [ $? -ne 0 ] && log "Sensor pkg can not be extracted" && cd $EXEC_DIR && return 1

  # In case of force upgrade we should not upgrade .deb if system is not already on .deb
  [ -e tet-sensor*.deb ] && [ ! -z $FORCE_UPGRADE ] && ! dpkg -s tet-sensor 2>/dev/null | grep Status: | grep installed && rm tet-sensor*.deb

  # install Debian package
  if [ -e tet-sensor*.deb ] ; then

    deb_pkg="$(ls tet-sensor*.deb| head -1 | awk '{print $1}')"
    deb_sig="$(ls tet-sensor*.sig| head -1 | awk '{print $1}')"
    opubkey="sensor-openssl.key"

    if [ ! -z $FORCE_UPGRADE ] ; then 
      cp $deb_pkg ${ACT_PREFIX}/conf_update.deb && cp $deb_sig ${ACT_PREFIX}/conf_update.sig && cd $EXEC_DIR && rm -rf $TMP_DIR
      [ $? -ne 0 ] && return 1
      return 0
    fi

    # Execute the rest from outside of temporary folder
    cd $EXEC_DIR

    log "Verifying Debian package ..."
    openssl dgst -sha256 -verify $TMP_DIR/$opubkey -signature $TMP_DIR/$deb_sig $TMP_DIR/$deb_pkg
    if [ $? -ne 0 ] ; then
        log "Error: Signature incorrect for Package >$deb_pkg<, Signature >$deb_sig< "
        return 1
    fi

    # Save zip file after signature check
    [ ! -z $SAVE_ZIP_FILE ] && cd $TMP_DIR && cp $TMP_FILE $SAVE_ZIP_FILE && cd $EXEC_DIR && return 0

    local dir=$(dirname $(dpkg -c $TMP_DIR/$deb_pkg | grep check_conf_update.sh$ | awk '{print $NF}' | sed "s#\.##g" ))
    local bdir=$(dirname $dir)
    local sdir=$(basename $dir)
    if [ ! -z $RELOC ] ; then
        if [ ${BASE_DIR} != ${bdir} ] || [ ${TET_SDIR} != ${sdir} ] ; then
            log "Error: Cannot relocate Debian package with prefix ${bdir}/${sdir} to ${BASE_DIR}/${TET_SDIR}"
            cd $EXEC_DIR && rm -rf $TMP_DIR && return 0
        fi
    fi
    BASE_DIR=$bdir
    TET_SDIR=$sdir
    if [ -z $LOG_PATH_CHANGED ] ; then
      LOGBDIR=$BASE_DIR
      LOGSDIR=$TET_SDIR
    fi

    # Install Debian package
    log "Installing Linux Sensor as Debian package to ${BASE_DIR}/${TET_SDIR} ..."
    # make sure we are starting from clean state
    preinstall_setup
    ret=0
    dpkg -i --force-confnew --debug=3 $TMP_DIR/$deb_pkg
    if [ $? -ne 0 ] ; then
      log "Error: the command dpkg -i has failed, please check errors"
      ret=1
    else
      log "### Installation succeeded"
    fi
    return $ret
  fi

  # copy the rpm file
  inner_rpm=$(ls tet-sensor*.rpm| head -1 | awk '{print $1}')
  [ ! -z $FORCE_UPGRADE ] && cp $inner_rpm ${ACT_PREFIX}/conf_update.rpm && cd $EXEC_DIR && rm -rf $TMP_DIR && return 0
  cp $inner_rpm $RPM_FILE

  # Execute the rest from outside of temporary folder
  cd $EXEC_DIR

  # Verify that the rpm package is signed by Tetration
  log "Verifying Linux RPM package ..."
  LOCAL_RPMDB=$TMP_DIR
  rpm --initdb --dbpath $LOCAL_RPMDB
  rpm --dbpath $LOCAL_RPMDB --import $TMP_DIR/sensor-gpg.key
  gpg_ok=$(rpm -K $TMP_DIR/$RPM_FILE --dbpath $LOCAL_RPMDB)
  ret=$?
  if [ $ret -eq 0 ] ; then
    pgp_signed=$(echo $gpg_ok | grep -e "gpg\|pgp" -e "signatures OK")
    if [ "$pgp_signed" = "" ] ; then
      log "Error: RPM signature verification failed"
      return 1
    else
      log "RPM package is PGP-signed"
    fi
  else
    log "Error: Cannot verify RPM package - $gpg_ok"
    return 1
  fi

  # Save zip file after signature check
  [ ! -z $SAVE_ZIP_FILE ] && cd $TMP_DIR && cp $TMP_FILE $SAVE_ZIP_FILE && cd $EXEC_DIR && return 0 

  if [ -z $RELOC ] ; then
    local dir=$(dirname $(rpm -qpil $TMP_DIR/$RPM_FILE 2>/dev/null | grep fetch_sensor_id.sh$))
    BASE_DIR=$(dirname $dir)
    TET_SDIR=$(basename $dir)
  fi
  if [ -z $LOG_PATH_CHANGED ] ; then
    LOGBDIR=$BASE_DIR
    LOGSDIR=$TET_SDIR
  fi
  log "Installing Linux Sensor to ${BASE_DIR}/${TET_SDIR}..."
  # make sure we are starting from clean state
  preinstall_setup

  RPM_INSTALL_OPTION=
  [ ! -z $RELOC ] && RPM_INSTALL_OPTION="${RPM_INSTALL_OPTION} --relocate /usr/local/tet=${BASE_DIR}/${TET_SDIR}"
  [ "$DISTRO" = "Ubuntu" ] && RPM_INSTALL_OPTION="${RPM_INSTALL_OPTION} --nodeps"
  ret=0
  rpm -Uvh $RPM_INSTALL_OPTION $TMP_DIR/$RPM_FILE
  if [ $? -ne 0 ] ; then
    log "Error: the command rpm -Uvh has failed, please check errors"
    ret=1
  else
    log "### Installation succeeded"
  fi
  return $ret
}

function upgrade {
  [ "$ACT_PREFIX" = "" ] && log "Failed to get basedir of installed sensor" && return 1
  if [ -z $SENSOR_VERSION ] ; then
    log "Upgrading to the latest version"
  else
    log "Upgrading to the provided version: $SENSOR_VERSION"
  fi
  # Download zip file and force upgrade
  if [ ! -z "$FORCE_UPGRADE" ] ; then
    perform_install
    [ $? -ne 0 ] && return 1
    # Set DONOT_DOWNLOAD
    [ ! -e ${ACT_PREFIX}/DONOT_DOWNLOAD ] && touch ${ACT_PREFIX}/DONOT_DOWNLOAD
    current_version=$(cat ${ACT_PREFIX}/conf/version)
    # Trigger check_conf_update
    PID=$(ps -ef | grep "tet-engine check_conf" | grep -v grep | awk {'print $2'})
    kill -USR1 $PID
    # Cleanup after upgrade
    count=0
    until [ $count -ge 6 ]
    do
      log "Checking upgrade status..."
      count=$[$count+1]
      sleep 15
      new_version=$(cat ${ACT_PREFIX}/conf/version)
      [ "$new_version" != "$current_version" ] && log "Upgrade succeeded" && rm -f ${ACT_PREFIX}/DONOT_DOWNLOAD && return 0
    done
    log "Upgrade timeout, cleaning up tmp files"
    rm -f ${ACT_PREFIX}/conf_update.rpm
    rm -f ${ACT_PREFIX}/conf_update.deb
    rm -f ${ACT_PREFIX}/DONOT_DOWNLOAD
    return 1
  fi
  # Send sensor version update request
  [ ! -e $UUID_FILE ] && log "$UUID_FILE does not exist" && return 1
  perform_install
  [ $? -eq 0 ] && log "Upgrade triggered" && return 0
  return 1
}

function cleanup_when_exit {
  echo "Cleaning up temporary files when exit"
  log "#### Installer script run ends @ $(date)"
  [ ! -z ${TMPLOG} ] && [ -d ${BASE_DIR}/${TET_SDIR}/log ] && cat ${TMPLOG} >> ${BASE_DIR}/${TET_SDIR}/log/tet-installer.log
  rm -f ${TMPLOG}
  if [[ -d $TMP_DIR ]] ; then
    tmp_dir=$(fullname "$TMP_DIR")
    # Remove tmp_dir only if it's in /tmp/ path
    case "$tmp_dir" in
      /tmp/*)
        rm -rf $tmp_dir
        ;;
    esac
  fi
}

trap cleanup_when_exit EXIT

log "#### Installer script run starts @ $(date): $0 $@"

for i in "$@"; do
case $i in
  --pre-check)
  PRECHECK_ONLY=1
  shift
  ;;
  --skip-pre-check=*)
  SKIP_PRECHECK="${i#*=}"
  [ "$SKIP_PRECHECK" != "all" ] && [ "$SKIP_PRECHECK" != "ipv6" ] && [ "$SKIP_PRECHECK" != "enforcement" ] && log "Invalid skip-pre-check option provided, pre-check will not be skipped." && SKIP_PRECHECK=
  shift
  ;;
  --no-install)
  NO_INSTALL=1
  shift
  ;;
  --logfile=*)
  LOG_FILE="${i#*=}"
  truncate -s 0 $LOG_FILE
  shift
  ;;
  --proxy=*)
  CL_HTTPS_PROXY="${i#*=}"
  case $CL_HTTPS_PROXY in https:*) 
    log "Only http protocol is supported toward the proxy" && exit 236 
  esac
  shift
  ;;
  --no-proxy)
  NO_PROXY=1
  shift
  ;;
  --sensor-version=*)
  SENSOR_VERSION="${i#*=}"
  shift
  ;;
  --file=*)
  SENSOR_ZIP_FILE=$(fullname "${i#*=}")
  shift
  ;;
  --save=*)
  SAVE_ZIP_FILE=$(fullname "${i#*=}")
  shift
  ;;
  --basedir=*)
  BASE_DIR=$(fullname "${i#*=}")
  if [ -z "$BASE_DIR" ] || [ "$BASE_DIR" = "/" ] ; then
      echo "basedir cannot be /"
      exit 240
  fi
  TET_SDIR="tetration"
  RELOC=1
  shift
  ;;
  --logbasedir=*)
  LOGBDIR=$(fullname "${i#*=}")
  LOGSDIR=tetration
  LOG_PATH_CHANGED=1
  shift
  ;;
  --new)
  CLEANUP=1
  shift
  ;;
  --reinstall)
  CLEANUP=1
  KEEP_CERT=1
  shift
  ;;
  --unpriv-user=*)
  UNPRIVILEGED_USER="${i#*=}"
  TEST_USER=${UNPRIVILEGED_USER}
  shift
  ;;
  --help)
  print_version
  echo
  print_usage
  exit 0
  shift
  ;;
  --version)
  print_version
  exit 0
  shift
  ;;
  --ls)
  LIST_VERSION="True"
  shift
  ;;
  --force-upgrade)
  FORCE_UPGRADE="True"
  shift
  ;;
  --upgrade-local)
  UUID_FILE="/"
  shift
  ;;
  --upgrade-by-uuid=*)
  UUID_FILE="${i#*=}"
  [ -z $UUID_FILE ] && log "filename for --upgrade-by-uuid cannot be empty" && exit 240
  UUID_FILE=$(fullname "$UUID_FILE")
  shift
  ;;
  --visibility)
  SENSOR_TYPE=sensor
  shift
  ;;
  *)
  echo "Invalid option: $@"
  print_usage
  exit 240
  ;;
esac
done

# Script needs to to be invoked as root
if [ "$UID" != 0 ] ; then
  log "Script needs to be invoked as root"
  exit 255
fi

check_host_version
CHECK_HOST_VERSION_RC=$?
case $DISTRO in
Ubuntu)
  if [ -z $RELOC ] ; then
    BASE_DIR=/opt/cisco
    TET_SDIR=tetration
  fi
esac

# The local path will also be set by parameter

[ "${UUID_FILE}" = "/" ] && UUID_FILE=${BASE_DIR}/${TET_SDIR}/sensor_id

# --pre-check runs pre-check only
if [ ${PRECHECK_ONLY} -eq 1 ] ; then
    pre_check
    PRECHECK_RET=$?
    if [ $PRECHECK_RET -ne 0 ] ; then
        log "Pre-check has failed with code $PRECHECK_RET, please fix the errors"
        exit $PRECHECK_RET
    fi
    exit 0
fi

check_basedir_for_installed_sensor
# Overwrite sensor_type for --reinstall
if [ ! -z $KEEP_CERT ] && [ "$ACT_PREFIX" != "" ] ; then
  NEW_SENSOR_TYPE=$(cat ${ACT_PREFIX}/sensor_type)
  if [ $? -ne 0 ] ; then
    log "Failed to locate sensor_type for installed agent"
  elif [ "${SENSOR_TYPE}" != "${NEW_SENSOR_TYPE}" ] ; then
    SENSOR_TYPE=${NEW_SENSOR_TYPE}
  fi
  # Retain installation path if --logbasedir is not provided
  if [[ -z $RELOC ]] ; then
    case $DISTRO in
    Ubuntu)
      log "Use fixed tet-base on Ubuntu hosts"
      ;;
    *)
      BASE_DIR=$(dirname $ACT_PREFIX)
      TET_SDIR=$(basename $ACT_PREFIX)
      RELOC=1
      ;;
    esac
  fi
  # Retain log path if --logbasedir is not provided
  if [[ -z $LOG_PATH_CHANGED ]] ; then
    if [ -L ${ACT_PREFIX}/log ] ; then
      log_sym_link=$(ls -l ${ACT_PREFIX}/log | awk '{print $NF}')
      LOGBDIR=$(dirname $log_sym_link)
      LOGSDIR=$(basename $log_sym_link)
      LOG_PATH_CHANGED=1
    fi
  fi
fi

# --ls to list all available sensor versions. will not download or install anything
if [ $LIST_VERSION = "True" ] ; then
  perform_install
  if [ $? -ne 0 ] ; then
    log "Failed to list all available sensor versions"
    exit 1
  fi
  exit 0
fi

# Download and save zip file
if [ ! -z $SAVE_ZIP_FILE ] ; then
  perform_install
  if [ $? -ne 0 ] ; then
    log "Failed to save zip file"
    exit 238
  fi
  exit 0
fi

# Make sure pre-check has passed
pre_check
PRECHECK_RET=$?
if [ $PRECHECK_RET -ne 0 ] ; then
  log "Pre-check has failed with code $PRECHECK_RET, please fix the errors"
  exit $PRECHECK_RET
fi

# Force upgrade to provided version
if [ ! -z $FORCE_UPGRADE ] || [ ! -z $UUID_FILE ] ; then
  upgrade
  [ $? -ne 0 ] && log "Sensor upgrade failed" && exit 237
  exit 0
fi

# Only proceed with installation if instructed
if [ $NO_INSTALL -eq 0 ] ; then
  NO_INSTALL=2
  perform_install
  if [ $? -ne 0 ] ; then
    log "Installation has failed, please check and fix the errors"
    exit 239
  fi
fi

log ""
log "### All tasks are done ###"
exit 0
