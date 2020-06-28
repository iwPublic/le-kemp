#!/bin/bash
#KEMP & ACME Certificate Handler
#08.01.2016 - Referenced Alexander Ganser
#08.05.2019 - Adaptation
#22.06.2020 - Major Revamp
#27.06.2020 - Added option for resync and upload

#Internal Script Functions
  sTimeStamp() {
    local result="$(date +"%Y-%m-%d") $(date +"%H:%M:%S")"
    echo $result
  }

  #TODO: Error Handling
  shout() {
    echo $1
    echo "$(sTimeStamp):ERROR:Terminating"
    exit 1
  }
  
  SendAlert() {
    echo $RUNLOG | mail -S $MAILSERVER -s "ALERT:KEMP & LetsEncrypt Integration" $MAILTO
  }

  showhelp() {
      echo ""
      echo "Usage:"
      echo "$0 [ -d <server.domain.tld> ] ( -o [compare|sync|upload] )"
      echo "$0 [ -d <server.domain.tld> ] ( -o [compare,sync,upload] )"
      echo ""
      echo "ACME-KEMP Certificate Handler"
      echo ""
      echo "  -d      Specify FQDN of the certificate"
      echo "  -o      Optional. Specify option or comma separated actions."
      echo "          compare - Compares the certificate on KEMP and Local"
      echo "          resync  - Synchronise local certificate with LetsEncrypt"
      echo "          upload  - Sends the local copy of the certificate to KEMP"
      echo "  -q      Quiet.  Only external commands are rendered - Not ready"
      echo "  -l      Log everything to /var/log/le-kemp/sync.log - Not ready"
      echo ""
      exit 2
  }

#Initialize
  while getopts d:o:ql opt
  do
    case $opt in
      d)
        DOMAIN=$(echo $OPTARG | grep -P '(?!:\/\/)(?=.{1,255}$)((.{1,63}\.){1,127}(?![0-9]*$)[a-z0-9-]+\.?)$')
        [ -z $DOMAIN ] && shout "-d requires a valid Fully Qualified Domain Name (FQDN)."
        DOMAIN=$OPTARG
        ;;
      o)
        OPTIONS=($(echo "$OPTARG" | tr ',' ' '))
        ;;
    esac
  done
  shift $((OPTIND -1))

  [ "$OPTIND" -eq 1 ] && showhelp && exit 2
  [ -z $DOMAIN ] && showhelp && exit 2

#Setup for Logs
  LOGFILE="/var/log/le-kemp/sync.log"
  MAILTO="user@domain.tld"
  MAILSERVER="127.0.0.1:25"

#Setup for Certificate Paths
  LO_CERT="./certificates/$DOMAIN/full.pem" #Path to local certificate
  LO_CERT_BAK="./certificates/$DOMAIN/full.bak" #Path to local backup certificate
  LE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"  #Source Private Key
  LE_CERT="/etc/letsencrypt/live/$DOMAIN/cert.pem"  #Source Public Key
  LE_CHAIN="/etc/letsencrypt/live/$DOMAIN/chain.pem" #Source Intermediate CA #TODO:Keep KEMP updated

#Setup for OpenSSL
  LTIME="5356800" #30 days in seconds

#Functions
  function iGetCertificateExpiry() {
    local result=$(openssl x509 -enddate -noout -in $1)
    local result=${result/notAfter=/}
    local result=$(date --date="$result" --utc +"%Y%j")
    return $result
  }

  function bCertificateValid() {
    openssl x509 -checkend $1 -noout -in $2
    local rc=$?
    return $rc
  }

  function RenewCertificate() {
    certbot certonly -d $1
    local rc=$?
    return $rc
  }

  function BackupLocalCertificate() {
    echo "$(sTimeStamp):INFO:Backup current local certificate to $LO_CERT_BAK"
    mv $LO_CERT $LO_CERT_BAK
  }

  function MakeLocalCertificate() {
    echo "$(sTimeStamp):INFO:Combining newer certificate $LO_CERT."
    cat $LE_CERT $LE_KEY > $LO_CERT
  }

  #Usage UploadCert(identity, certificate_path, server, domain)
  function CurlPOST() {
    curl -f -k -E $1 --data-binary @$2 "https://$3/access/addcert?cert=$4&replace=1"
    local rc=$?
    return $rc
  }

  #Usage BackupCert(identity, server, domain)
  function CurlGET() {
    curl -f -k -G -E $1 "https://$2/access/readcert?cert=$3"
    local rc=$?
    return $rc
  }

  function UploadLocalCertificate() {
    for TARGET in ${TARGETS[@]}
      do
       IFS="," && read IP PEM <<< $TARGET
        echo "$(sTimeStamp):INFO Starting upload to $IP using $PEM"
        CurlPOST $PEM $LO_CERT $IP $DOMAIN
        local rc=$?
        [ $rc != 0 ] && shout "$(sTimeStamp):ERROR:Code $rc received for $IP"
      done
  }

#Initialize
  cd /usr/local/sbin/le-kemp
  [ ! -f ./handler.conf ] && shout "$(sTimeStamp):ERROR:Configuration file not found."
  [ ! -f $LE_KEY ] && shout "$(sTimeStamp):ERROR:Source Private Key not found."
  [ ! -f $LE_CERT ] && shout "$(sTimeStamp):ERROR:Source Certificate not found."
  [ ! -d ${LO_CERT%/*} ] && mkdir -pm700 ${LO_CERT%/*} &&
  if [ $? -ne 0 ]; then
    shout "ERROR:Unable to create directory for $LO_CERT"
  else
    echo "WARN:Directory was created for $LO_CERT"
  fi
  [ ! -f $LO_CERT ] && MakeLocalCertificate && echo "WARN:Sync $LO_CERT from $LE_CERT"
  TARGETS=$(sed -nE "/\[[Targets]*\]/{:l n;/^(\[.*\])?$/q;p;bl}" handler.conf)

#Main
  if [ ${#OPTIONS[@]} -gt 0 ]; then
    for i in ${OPTIONS[@]}
      do
        case $i in
          "compare")
          shout "TODO: Not done yet - Download and Compare"
          ;;
          "resync")
          echo "INFO: Options specified for resync"
          BackupLocalCertificate
          MakeLocalCertificate
          ;;
          "upload")
          UploadLocalCertificate
          ;;
        esac
      done
  elif [ -z $OPTIONS ]; then
    echo "$(sTimeStamp):INFO:Checking certificate $LO_CERT."
    if (bCertificateValid $LTIME $LO_CERT); then
      echo "$(sTimeStamp):INFO:Certificate $LO_CERT is within specifications."
      exit 0
    else
      echo "$(sTimeStamp):INFO:Certificate $LO_CERT not within specifiations."
      if [ $(iGetCertificateExpiry $LO_CERT) -lt $(iGetCertificateExpiry $LE_CERT) ]; then
        echo "$(sTimeStamp):INFO:Certificate $LE_CERT is within specifications."
        BackupLocalCertificate
        MakeLocalCertificate
        UploadLocalCertificate
      else
        echo "$(sTimeStamp):WARN:Attempt to renew certificate $LE_CERT."
        if [ $(RenewCertificate $DOMAIN) == 0 ]; then #Untested/Unconfirmed on certbot RC.
          BackupLocalCertificate
          MakeLocalCertificate
          UploadLocalCertificate
        else
          shout "$(sTimeStamp):ERROR:Nothing else can be done."
        fi
      fi
    fi
  fi
  exit 0
