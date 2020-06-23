#!/bin/bash
#KEMP & LetsEncrypt certbot Integration
#08.01.2016 - Pull from Alexander Ganser
#08.05.2019 - Dave Wee
#22.06.2020 - Dave Wee
    #- Accomodate ACME certbot functionality changes.
    #- Depends on systemd certbot.timer
    #- certbot.timer auto renews certificates
    #- Issue "certbot certificates" to verify existence

#Check for parameter first
[ -z "$1" ] && echo "Error: Expected domain name as parameter." && exit 2

#Setup for Logs
LOGFILE="/var/log/le-kemp/sync.log"
MAILTO="email@domain.tld"
MAILSERVER="127.0.0.1"

#Setup for Certificate Paths
DOMAIN=$1
LO_CERT="/usr/local/sbin/le-kemp/certificates/$DOMAIN/merged.pem" #Path to local certificate
LO_CERT_BAK="/usr/local/sbin/le-kemp//certificates/$DOMAIN/merged.bak" #Path to local backup certificate
LE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"  #Source Private Key
LE_CERT="/etc/letsencrypt/live/$DOMAIN/cert.pem"  #Source Public Key
LE_CHAIN="/etc/letsencrypt/live/$DOMAIN/chain.pem" #Source Intermediate CA #TODO:Keep KEMP updated

#Setup for OpenSSL
LTIME="2592000" #30 days in seconds

#Setup for KEMP API :TODO Make this elegant KV array
KEMP1="127.0.0.1:443"
KEMP2="127.0.0.2:443"
KEMP1_PEM="/usr/local/sbin/le-kemp/identity/1.api.cert.pem"
KEMP2_PEM="/usr/local/sbin/le-kemp/identity/2.api.cert.pem"

#Check requirements
[ ! -f $LO_CERT ] && echo "Error: Local Certificate not found." && exit 2
[ ! -f $LE_KEY ] && echo "Error: Source Key not found." && exit 2
[ ! -f $LE_CERT ] && echo "Error: Source Certificate not found." && exit 2

#Simple Functions
  function SendAlert() {
    mail -s $MAILSERVER "ALERT: KEMP & LetsEncrypt Integration" $RUNLOG
  }

  #result="$GetDateCertificateExpiry(CertificatePath)"
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

  function KempAddCert() {
    curl -E $1 -X POST --data-binary @$2 -kv "https://$3/access/addcert?cert=$4&replace=1"
    return $?
  }

  function MakeCertificate() {
    cat $1 $2 > $3
  }

  function RenewCertificate() {
    certbot certonly -d $1
    return $?
  }

  function TimeStamp() {
    local result="$(date +"%Y-%m-%d") $(date +"%H:%M:%S")"
    echo $result
  }

#Functions #TODO: Use fallback
  function BKCERT() {
    echo "$(TimeStamp):INFO:Backing up older local certificate. $LO_CERT to $LO_CERT_BAK."
    mv $LO_CERT $LO_CERT_BAK
  }

  function MKCERT() {
    echo "$(TimeStamp):INFO:Combining newer $LE_CERT and $LE_KEY."
    MakeCertificate $LE_CERT $LE_KEY $LO_CERT
  }

  #Usage: ULCERT($CLIENTCERT $LO_CERT $KEMP1/2 $DOMAIN)
  function ULCERT() {
  echo "$(TimeStamp):INFO:Starting upload to KEMP."
  KempAddCert $1 $2 $3 $4
  if [$? -eq 0 ]
  then
    echo "$(TimeStamp):INFO:Upload to $3 completed."
    return $?
  else
    echo "$(TimeStamp):ERROR:Upload to $3 encountered errors."
    return $?
  fi
  }

#Conditional Sequence
  echo "$(TimeStamp):INFO:Checking against local cache."
  if (bCertificateValid $LTIME $LO_CERT)
  then
    echo "$(TimeStamp):INFO:Certificate $LO_CERT is within specifications."
    exit 0
  else
    echo "$(TimeStamp):INFO:Certificate $LO_CERT not within specifiations."
    echo "$(TimeStamp):INFO:Check certificate from $LE_CERT."
    if [ $(iGetCertificateExpiry $LO_CERT) -lt $(iGetCertificateExpiry $LE_CERT) ]
    then
      #TODO: Make this elegant
      BKCERT
      MKCERT
      if [ $(ULCERT $KEMP1_PEM $LO_CERT $KEMP1 $DOMAIN) -eq 0 && $(ULCERT $KEMP2_PEM $LO_CERT $KEMP2 $DOMAIN) -eq 0 ]
      then
        exit 0
      else
        exit 1
      fi
    else
      echo "$(TimeStamp):WARN:LetsEncrypt certificate is not newer than local cache."
      echo "$(TimeStamp):WARN:Attempting to renew LetsEncrypt Certificate."
      if [ $(RenewCertificate $DOMAIN) -eq 0 ]
      then
        if [ $(iGetCertificateExpiry $LO_CERT) -lt $(iGetCertificateExpiry $LE_CERT) ]
        then
        #TODO: Make this elegant
        BKCERT
        MKCERT
        if [ $(ULCERT $KEMP1_PEM $LO_CERT $KEMP1 $DOMAIN) -eq 0 && $(ULCERT $KEMP2_PEM $LO_CERT $KEMP2 $DOMAIN) -eq 0 ]
        then
          exit 0
        else
          exit 1
        fi
      else
        echo "$(TimeStamp):ERROR:Certbot exited with error code - Refer to LetsEncrypt logs."
        echo "$(TimeStamp):ERROR:Nothing else can be done."
        exit 1
      fi
    fi
  fi
fi
exit 0
