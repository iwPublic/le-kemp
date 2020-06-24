#!/bin/bash
#KEMP & LetsEncrypt certbot Integration
#08.01.2016 - Referenced Alexander Ganser
#08.05.2019 - Adaptation
#22.06.2020 - Major Revamp

#Pre-Initialize
  [ -z "$1" ] && echo "ERROR:Expected minimally domain name as parameter." && exit 2
  [ $2 = "resync "] && echo "INFO:Resync is specified." && RESYNC = true
  cd /usr/local/sbin/le-kemp

#Setup for Logs
  LOGFILE="/var/log/le-kemp/sync.log"
  MAILTO="user@domain.tld"
  MAILSERVER="127.0.0.1:25"

#Setup for Certificate Paths
  DOMAIN=$1
  LO_CERT="./certificates/$DOMAIN/full.pem" #Path to local certificate
  LO_CERT_BAK="./certificates/$DOMAIN/full.bak" #Path to local backup certificate
  LE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"  #Source Private Key
  LE_CERT="/etc/letsencrypt/live/$DOMAIN/cert.pem"  #Source Public Key
  LE_CHAIN="/etc/letsencrypt/live/$DOMAIN/chain.pem" #Source Intermediate CA #TODO:Keep KEMP updated

#Setup for OpenSSL
  LTIME="5356800" #30 days in seconds

#Setup for KEMP API :TODO Make this elegant KV array
  KEMP1="127.0.0.1:443"
  KEMP2="127.0.0.2:443"
  KEMP1_PEM="./identity/1.api.cert.pem"
  KEMP2_PEM="./identity/2.api.cert.pem"

#Internal Script Functions
  function SendAlert() {
    echo $RUNLOG | mail -S $MAILSERVER -s "ALERT:KEMP & LetsEncrypt Integration" $MAILTO
  }
  
  function sTimeStamp() {
    local result="$(date +"%Y-%m-%d") $(date +"%H:%M:%S")"
    echo $result
  }

#Functions #TODO: Enable fallback  
  function iGetCertificateExpiry() {
    local result=$(openssl x509 -enddate -noout -in $1)
    local result=${result/notAfter=/}
    local result=$(date --date="$result" --utc +"%Y%j")
    echo $result
  }

  function bCertificateValid() {
    openssl x509 -checkend $1 -noout -in $2
    return $?
  }

  function RenewCertificate() {
    certbot certonly -d $1
    return $?
  }

  function BackupLocalCertificate() {
    mv $LO_CERT $LO_CERT_BAK
  }

  function MakeLocalCertificate() {
    cat $LE_CERT $LE_KEY > $LO_CERT
  }

  function UploadCert() {
    curl -f -k -E $1 --data-binary @$2 "https://$3/access/addcert?cert=$4&replace=1"
    echo $?
  }

#Routines
  function BKMKUL() {
    echo "$(sTimeStamp):INFO:Backing up older local certificate to $LO_CERT_BAK"
    BackupLocalCertificate
    echo "$(sTimeStamp):INFO:Making certificate $LO_CERT."
    MakeLocalCertificate
    echo "$(sTimeStamp):INFO:Starting upload to $KEMP1 and $KEMP2..."
    UL
  }

  function UL() {
    echo "$(sTimeStamp):INFO:Starting upload to $KEMP1 and $KEMP2..."
    rcA=$(UploadCert $KEMP1_PEM $LO_CERT $KEMP1 $DOMAIN)
    rcB=$(UploadCert $KEMP2_PEM $LO_CERT $KEMP2 $DOMAIN)
    if [[ $rcA = 0 && $rcB = 0 ]]
    then
      echo "$(sTimeStamp):INFO:All uploads completed successfully."
      exit 0
    else
      echo "$(sTimeStamp):ERROR:Code $rcA returned for $KEMP1 and $rcB returned for $KEMP2"
      echo "$(sTimeStamp):ERROR:One or more of the upload to KEMP has encountered issues."
      exit 1
    fi
  }

#Initialize
  [ ! -f $LE_KEY ] && echo "ERROR:Source Private Key not found." && exit 2
  [ ! -f $LE_CERT ] && echo "ERROR:Source Certificate not found." && exit 2
  [ ! -d ${LO_CERT%/*} ] && mkdir -pm700 ${LO_CERT%/*} && echo "WARN:Directory specified did not exist.  Created ${LO_CERT%/*}"
  [ ! -f $LO_CERT ] && MakeLocalCertificate && echo "WARN:$LO_CERT was not found.  Created $LO_CERT"

#Main
  echo "$(sTimeStamp):INFO:Checking against local cache."
  if (bCertificateValid $LTIME $LO_CERT)
  then
    echo "$(sTimeStamp):INFO:Certificate $LO_CERT is within specifications."
    if [ $RESYNC = true ]
    then
      UL
    else
      exit 0
    fi
  else
    echo "$(sTimeStamp):INFO:Certificate $LO_CERT not within specifiations."
    echo "$(sTimeStamp):INFO:Checking certificate from $LE_CERT."
    if [ $(iGetCertificateExpiry $LO_CERT) -lt $(iGetCertificateExpiry $LE_CERT) ]
    then
      echo "$(sTimeStamp):INFO:Certificate $LE_CERT expires later than $LO_CERT"
      echo "$(sTimeStamp):INFO:Make and upload certificate $LO_CERT"
      BKMKUL
    else
      echo "$(sTimeStamp):WARN:Certificate $LE_CERT is not newer than $LO_CERT"
      echo "$(sTimeStamp):WARN:Attempting to renew source certificate."
      if [[ $(RenewCertificate $DOMAIN) = 0 ]]
      then
        BKMKUL
      else
        echo "$(sTimeStamp):ERROR:Certbot exited with error code - Refer to LetsEncrypt logs."
        echo "$(sTimeStamp):ERROR:Nothing else can be done."
        exit 1
      fi
    fi
  fi
  exit 0
