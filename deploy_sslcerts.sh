#!/bin/bash
umask 022

####################################################################################################
## This script is intended to automate some of the tasks involved in deploying SSL certs for POS.
## The script performs the following:
##  1. Shutdown BO in background for all the stores affected by the SSL cert deployment
##  2. Check BO to confirm shutdown
##     a. identify stores which did not shutdown
##     b. for stores with BO shutdown, do:
##        - take backup of cert files
##        - scp -p posbostore.jks and posbotrust.jks to each store at /apps/keys/certs_<5digit_store#>
##        - chmod 644 *jks
##        - restart BO in background for all stores that were successfully shutdown
##  3. For stores not shutdown, re-attempt BO shutdown
##  4. Restart BO for stores which successfully shutdown
##  5. If any stores failed shutdown or restart, send email notification and write ERROR to log.
##
##  NOT PART OF SCRIPT:
##  - Manually deploy ssl certs for those stores which failed to complete per the script.
##  - Bounce POS application
##
## USAGE:
##     deploy_sslcerts.sh -d <directory containing certs> -s <store/server list> -c <cert type to deploy>
##
## INPUTS:
##  1. Directory containing new certs
##     Example:  /tmp/newcert/20181024
##               where ssl certs to be deployed will be in a directory structure similar to below:
##                     /tmp/newcert/20181024/ophipos06026.appl.kp.org/posbostore.jks
##                     /tmp/newcert/20181024/ophipos06026.appl.kp.org/posbotrust.jks
##  2. Store list containing 5-digit store # and store VIP/server name separated by a pipe (|).
##  3. Cert type to deploy.  It can be either trust, store, or both.  If both is specified, then
##     the posbostore.jks and posbotrust.jks are deployed.
#####################################################################################################

## function backup_and_deploy_certs - backs up old certs and scp new certs to target server
function backup_and_deploy_certs {

    echo "Backing up $DEPLOY_OPTION existing cert(s) to <file>.${DTSTMP} and copying $DEPLOY_OPTION cert(s) to $STORE" >> $LOG

    ## backup, deploy, and chmod posbostore.jks
    if [[ "$DEPLOY_OPTION" == "store" || "$DEPLOY_OPTION" == "both" ]];then
        # backup ssl certs
        ssh -q -f wasadm@${SERVER} "cp -p /apps/keys/certs_${STORE}/posbostore.jks /apps/keys/certs_${STORE}/posbostore.jks.$DTSTMP"

        # scp new certs to STORE
        scp -p $SRCDIR/$SERVER/posbostore.jks wasadm@${SERVER}:/apps/keys/certs_${STORE}/ >> $LOG 2>/dev/null

        # chmod 644 new certs
        ssh -q -f wasadm@${SERVER} "chmod 644 /apps/keys/certs_${STORE}/posbostore.jks"
    fi

    ## backup, deploy, and chmod posbotrust.jks
    if [[ "$DEPLOY_OPTION" == "trust" || "$DEPLOY_OPTION" == "both" ]];then
        ssh -q -f wasadm@${SERVER} "cp -p /apps/keys/certs_${STORE}/posbotrust.jks /apps/keys/certs_${STORE}/posbotrust.jks.$DTSTMP"

        scp -p $SRCDIR/$SERVER/posbotrust.jks wasadm@${SERVER}:/apps/keys/certs_${STORE}/ >> $LOG 2>/dev/null

        ssh -q -f wasadm@${SERVER} "chmod 644 /apps/keys/certs_${STORE}/posbotrust.jks"
    fi
}

## function confirmChksums - confirms no file corruption during scp
function confirmChksums {
    # confirm checksums of new certs
    chk1=0
    chk2=0

    if [[ "$DEPLOY_OPTION" == "store" || "$DEPLOY_OPTION" == "both" ]];then
        src1_cksum=`cksum $SRCDIR/$SERVER/posbostore.jks | sed 's# .*##'`
        tgt1_cksum=`ssh -q wasadm@${SERVER} "cksum /apps/keys/certs_${STORE}/posbostore.jks | sed 's# .*##'"`
        echo "src1_cksum = $src1_cksum || tgt1_cksum = $tgt1_cksum" >> $LOG
        if [[ "$src1_cksum" == "$tgt1_cksum" ]];then
            chk1=1
        fi
    fi

    if [[ "$DEPLOY_OPTION" == "trust" || "$DEPLOY_OPTION" == "both" ]];then
        src2_cksum=`cksum $SRCDIR/$SERVER/posbotrust.jks | sed 's# .*##'`
        tgt2_cksum=`ssh -q wasadm@${SERVER} "cksum /apps/keys/certs_${STORE}/posbotrust.jks | sed 's# .*##'"`
        echo "src2_cksum = $src2_cksum || tgt2_cksum = $tgt2_cksum" >> $LOG
        if [[ "$src2_cksum" == "$tgt2_cksum" ]];then
            chk2=1
        fi
    fi

    chktot=$((chk1+chk2))

    if [[ "$DEPLOY_OPTION" == "both" && $chktot -eq 2 ]];then
        return 1
    elif [[ "$DEPLOY_OPTION" == "store" || "$DEPLOY_OPTION" == "trust" ]] && [[ $chktot -eq 1 ]];then
        return 1
    else
        return 0
    fi
}

## function chkSshAccess - checks server for ssh access.  If ok, returns 1 otherwise 0
function chkSshAccess {
        # check if store is accessible
        ssh -q -o PreferredAuthentications=publickey -o LogLevel=Error -o StrictHostKeyChecking=no wasadm@${SERVER} exit
        EXIT_CODE1="$?"

        # if accessible, return 1
        if [[ ${EXIT_CODE1} -eq 0 ]]; then
        return 1
        else
        return 0
        fi
}

## function chkIfServerUp - checks if BO app is down.  if so, return 1
function chkIfServerUp {
    grep "Server_${STORE} open for e-business" $START_STOP_OUTPUT > /dev/null
    if [[ $? -eq 0 ]];then
        return 1
    else
        return 0
    fi
}

## function chkIfServerDown - checks if BO app is down.  if so, return 1
function chkIfServerDown {
    ps_out=`ssh -q -f wasadm@${SERVER} "ps -ef | grep Server_${STORE} | grep wasadm | grep -v grep"`

    # if server is down, return 1 else 0
    if [[ -z $ps_out ]];then
        return 1
    else
        return 0
    fi
}


## function prtUsage - displays script usage including required arguments
function prtUsage {
    echo ""
    echo "USAGE  :  ${PROG}.sh -d <DIR CONTAINING CERTS> -s <STORE/SERVER LIST> -c <CERT TO DEPLOY>"
    echo "                where -d option is the directory that contains the server or VIP sub-directory."
    echo "                      The server/VIP sub-directory would contain the individual .jks certs."
    echo "                and -s option specifies the file containing a list of stores vs server delimited by a pipe (|)."
    echo "                      The server name must be same name as shown in the directory structure specified in -d option."
    echo "                and -c option can be one of 3 values:  trust, store, or both."
    echo "                      trust option means deploy only posbotrust.jks"
    echo "                      store option means deploy only posbostore.jks"
    echo "                      both option means deploy both .jks cert files"
    echo ""
    echo "EXAMPLE:  ${PROG}.sh -d /tmp/pos_sslcerts/20181212  -s /tmp/pos_sslcerts/storeLIST.txt -c both"
    echo ""
    exit 1
}

##########
##  MAIN
##########

## Check arguments
PROG=`basename $0 | sed 's#\.sh$##'`
if [[ $# -lt 6 ]];then
    echo "ERROR:  Invalid number of arguments."
    prtUsage
fi


## Read and validate arguments
while [[ ! -z $1 ]];
do
    case $1 in
        -d) shift
            echo $1 | grep '^\/' >/dev/null 2>&1
            if [[ $? -eq 0 ]];then
                # full path to cert source directory is provided
                SRCDIR=$1
            else
                # relative path to cert source directory provided
                SRCDIR=`pwd`/$1
            fi
            if [[ ! -d $SRCDIR ]];then
                echo "ERROR:  The supplied source directory does not exist."
                exit 2
            fi
            ;;
        -s) shift
            # set STORELIST to full path format if argument provided as relative path
            echo $1 | grep '^\/' >/dev/null 2>&1
            if [[ $? -eq 0 ]];then
                # full path to storelist provided
                STORELIST=$1
            else
                # relative path to storelist provided
                STORELIST=`pwd`/$1
            fi
            # clean storelist, set to pipe-delimited
            cat $STORELIST | tr '\t' ' ' | sed 's#  *# #g' | sed 's#^ *##' | sed 's# *$##' | sed 's#^\|*##' | sed 's#\|*$##' | sed 's# *\|#|#g' | sed 's#\| *#|#g' | sed 's# #|#g' > ${STORELIST}.clean
            STORELIST="${STORELIST}.clean"
            ;;
        -c) shift
            DEPLOY_OPTION=$1
            if [[ "$DEPLOY_OPTION" != "trust" && "$DEPLOY_OPTION" != "store" && "$DEPLOY_OPTION" != "both" ]];then
                echo "ERROR:  The supplied cert type to deploy must be either store, trust, or both."
            prtUsage
            fi
            ;;
        *)  echo "ERROR:  Unknown option specified."
            prtUsage
    esac
    shift
done

WRKDIR=`pwd`
cd $SRCDIR

## Check if directory contains the required number of files
if [[ "$DEPLOY_OPTION" == "store" ]];then
    regex="posbostore.jks"
    expected_jks_cnt=1
elif [[ "$DEPLOY_OPTION" == "trust" ]];then
    regex="posbotrust.jks"
    expected_jks_cnt=1
else
    regex="posbostore.jks|posbotrust.jks"
    expected_jks_cnt=2
fi
cert_names=`cat $STORELIST | awk 'BEGIN{FS="|"}{print $2}'`

find_cnt=`find $cert_names | egrep "$regex" | wc -l | awk '{print $1}'`
list_cnt=`cat $STORELIST | wc -l | awk '{print $1}'`
if [[ "$DEPLOY_OPTION" == "both" ]];then
    list_cnt=$((list_cnt*2))
fi


if [[ $find_cnt -ne $list_cnt ]];then
    echo "ERROR:  For the specified store list, $SRCDIR is missing 1 or more .jks certs.  Add the missing cert(s) to $SRCDIR or remove the item(s) from $STORELIST."
    exit 1
fi


## Define variables
TSTMP=`date +"%Y%m%d_%H%M%S"`
DTSTMP=`date +"%Y%m%d"`
LOGDIR=$WRKDIR/logs
mkdir -p $LOGDIR
LOG=$LOGDIR/$PROG.log.$TSTMP
ERRLOG=$LOGDIR/$PROG.error.$TSTMP
OK_LOG=$LOGDIR/successful_stores.txt
FAILED_STORES=$LOGDIR/failed_stores.txt
RESULT_SUMRY=$LOGDIR/sumry_cert_deploymt.txt.$TSTMP
LOOP2LIST=$LOGDIR/chk_store_down.txt
RESTARTEDSTORES=$LOGDIR/restarted_stores.txt
START_STOP_OUTPUT=$LOGDIR/start_stop_output.txt


## Remove files older than 2 weeks and create/zero out existing files
for logfile in `find $LOGDIR -type f -mtime +14 | egrep "$LOGDIR/$PROG.log|$LOGDIR/$PROG.error|$LOGDIR/sumry_cert_deploymt.txt"`
do
    /usr/bin/rm $logfile
done
> $LOG
> $ERRLOG
> $OK_LOG
> $FAILED_STORES
> $RESULT_SUMRY
> $LOOP2LIST
> $RESTARTEDSTORES
> $START_STOP_OUTPUT


## Use input directory as working directory
cd $SRCDIR


## Get count of stores to update from input STORELIST
echo "--- Executing step 1 of 5: checking ssl access"
store_cnt=`grep -v ^$ $STORELIST | wc -l | awk '{print $1}'`


echo "" >> $LOG
echo "-----------------" >> $LOG
## Loop through list of stores to initiate BO shutdown for all affected stores
echo "STEP 1:  Check ssh access to stores in $STORELIST" >> $LOG
cnt=0
for LINE in `cat $STORELIST`
do
    # Check record to make sure pipe-delimited
    field_cnt=`echo $LINE | awk 'BEGIN{FS="|"}{print NF}'`
    if [[ $field_cnt -ne 2 ]];then
        echo "LINE:  $LINE"
        echo "ERROR:  Incorrect number of fields provided.  Check $STORELIST to confirm fields are pipe-delimited."
        exit 3
    fi

    cnt=$((cnt+1))
    STORE=`echo $LINE | cut -d'|' -f1`
    SERVER=`echo $LINE | cut -d'|' -f2`
    # provide update of script progress
    echo "Processing store $STORE ($SERVER) ... #${cnt} of $store_cnt"

    # check if server directory exists in the provided source directory
    find . -type d | grep '.kp.org$' | grep $SERVER
    if [[ $? -eq 0 ]];then
        # check if both new *.jks certs exist in source directory
        dir=`find . -type d  | grep "${SERVER}"`
        basedir=`basename $dir`
        jks_cnt=`ls $dir | egrep 'posbostore|posbotrust' | wc -l | awk '{print $1}'`
        if [[ $jks_cnt -ne $expected_jks_cnt ]];then
            echo "ERROR: $STORE - jks cert count not valid for $basedir" >> $ERRLOG;
        fi
    else
        echo "ERROR: $STORE - ssl cert source directory does not exist."
    fi

    # check if store is accessible
    echo "Checking if ssh access to $SERVER" >> $LOG
    chkSshAccess
    accessOK=$?
    echo "$STORE:  accessOK = $accessOK" >> $LOG

    # if accessible, stop BO
    if [[ $accessOK -eq 1 ]]; then
        echo "Executing command in background to stop BO server for store $STORE" >> $LOG
        ssh -q -f wasadm@${SERVER} "sh -c 'umask 022 &&  /apps/WebSphere/AppServer-8.5/profiles/UNManagedProd${STORE}/bin/stopServer.sh Server_${STORE} &'" >> $START_STOP_OUTPUT 2>&1
        echo "$STORE|$SERVER" >> $LOOP2LIST
    else
        echo "WARNING: ${STORE} - Unable to ssh to ${SERVER}, continuing to shutdown remaining stores." >> $LOG
    fi
done
echo "----------------- END STEP 1" >> $LOG

# sleep 2.5 minutes to allow BO to shutdown before proceeding
echo "Sleeping for 2.5 minutes to allow BO to shutdown."
sleep 150



echo "--- Executing step 2 of 5:  check if BO is down, deploy certs, and restart BO"
## Loop through list of accessible stores to check if BO is down, backup certs, scp new certs, confirm cksums, chmod new files, and restart BO for all affected stores
echo "STEP 2:  Check if BO shutdown and if so, backup old certs, deploy new certs, and re-start BO." >> $LOG
for LINE in `cat $LOOP2LIST`
do
    STORE=`echo $LINE | cut -d'|' -f1`
    SERVER=`echo $LINE | cut -d'|' -f2`

    echo " Checking BO is shutdown for store $STORE" >> $LOG
    chkIfServerDown
    server_down=$?

    if [[ $server_down -eq 1 ]];then
        echo "BO for $STORE is successfully shutdown" >> $LOG
        backup_and_deploy_certs

        confirmChksums

        # restart BO if cksum of new cert file(s) match source files
        if [[ $? -eq 1 ]];then
            # restart BO
            echo "Cert(s) successfully copied to $STORE" >> $LOG
            echo "Starting BO for $STORE in $SERVER" >> $LOG
            echo "$STORE|$SERVER" >> $RESTARTEDSTORES
            ssh -q -f wasadm@${SERVER} "sh -c 'umask 022 && /apps/WebSphere/AppServer-8.5/profiles/UNManagedProd${STORE}/bin/startServer.sh Server_${STORE} &'" >> $START_STOP_OUTPUT 2>&1
        else
            echo "ERROR: $STORE - scp failed" >> $ERRLOG
        fi
    else
        echo "WARNING: $STORE - After waiting 2.5 minutes, BO has not shutdown.  Will re-check again." >> $LOG
    fi
done
echo "----------------- END STEP 2" >> $LOG



echo "--- Executing step 3 of 5:  redo stores that failed initial ssh check"
## Check error log to see if unable to ssh to any stores.  If any found, retry to deploy certs and wait 2.5 minutes.
REDOLIST1=`grep 'Unable to ssh' $LOG | sed 's#^WARNING: \(.*\) - .*$#\1#'`
echo "REDOLIST1 = $REDOLIST1"
waitForRedo1=0
echo "STEP 3:  Re-attempt to stop BO if any stores failed initial check of ssh access" >> $LOG
if [[ ! -z $REDOLIST1 ]];then
    for STORE in `echo $REDOLIST1`
    do
        SERVER=`grep "^$STORE" $STORELIST | cut -d'|' -f2`
        chkSshAccess
        accessOK=$?
        if [[ $accessOK -eq 1 ]];then
            echo "RETRY: $STORE - Executing command in background to stop BO server" >> $LOG
            ssh -q -f wasadm@${SERVER} "sh -c 'umask 022 &&  /apps/WebSphere/AppServer-8.5/profiles/UNManagedProd${STORE}/bin/stopServer.sh Server_${STORE} &'" >> $START_STOP_OUTPUT 2>&1
            waitForRedo1=1
        else
            echo "ERROR: ${STORE} - Unable to ssh to ${SERVER} for a 2nd time, continuing to shutdown remaining stores on REDOLIST1." >> $ERRLOG
        fi
    done

    if [[ $waitForRedo1 -eq 1 ]];then
        echo "ssh access re-try was successfully initiated for at least 1 store.  Stop command was issued; so, waiting another 2.5 minutes." >> $LOG
        echo "Sleeping for 2.5 minutes to allow BO to shutdown for stores not shutdown on first pass."
        sleep 150
    fi
fi
echo "----------------- END STEP 3" >> $LOG


echo "--- Executing step 4 of 5:  after 2.5 additional minutes, redo shutdown check on stores not passing initial shutdown check.  If BO now stopped, deploy certs and restart BO"
## Check error log to see if any stores did not shut down.  If so, wait 2.5 minutes (if a second wait not already done) and retry to deploy certs
REDOLIST2=`egrep 'After waiting 2.5 minutes, BO has not shutdown|RETRY:.*to stop BO server' $LOG | sed -e 's#^WARNING: \(.*\) - .*$#\1#' -e 's#^RETRY: \(.*\) - .*$#\1#'`
echo "STEP 4:  Checking if BO successfully shutdown for any stores on redo list." >> $LOG
echo "REDOLIST2 = $REDOLIST2"
if [[ ! -z $REDOLIST2 ]];then
    ## If a second wait period not yet imposed, then sleep 2.5 minutes
    if [[ $waitForRedo1 -ne 1 ]];then
        echo "All stores on REDOLIST1 failed ssh access a 2nd time or there are no stores on the list." >> $LOG
        echo "Sleeping for 2.5 minutes to allow BO to shutdown for stores not shutdown on first pass."
        sleep 150
    fi

    for STORE in `echo $REDOLIST2`
    do
        SERVER=`grep "^$STORE" $STORELIST | cut -d'|' -f2`
        echo " Re-checking BO is shutdown for store $STORE" >> $LOG


        chkIfServerDown
        server_down=$?

        if [[ $server_down -eq 1 ]];then
            echo "BO for $STORE is successfully shutdown" >> $LOG
            backup_and_deploy_certs

            confirmChksums

            # restart BO if cksum of new cert files match source files
            if [[ $? -eq 1 ]];then
                echo "Certs successfully copied to store $STORE" >> $LOG
                # restart BO
                echo "STARTING BO SERVER for $STORE in $SERVER" >> $LOG
                echo "$STORE|$SERVER" >> $RESTARTEDSTORES
                ssh -q -f wasadm@${SERVER} "sh -c 'umask 022 && /apps/WebSphere/AppServer-8.5/profiles/UNManagedProd${STORE}/bin/startServer.sh Server_${STORE} &'" >> $START_STOP_OUTPUT 2>&1
                if [[ $? -ne 0 ]];then
                    echo "ERROR: $STORE - ssh failed on second try, manually deploy the cert." >> $ERRLOG
                fi
            else
                echo "ERROR: $STORE - scp failed" >> $ERRLOG
            fi
        else
            echo "ERROR: $STORE - After waiting 10 minutes, BO still has not shutdown.  Will not retry deploying cert, manually deploy the cert." >> $ERRLOG
        fi
    done
fi
echo "----------------- END STEP 4" >> $LOG


echo "--- Executing step 5 of 5:  check BO restarted for stores passing previous steps."
## Loop through the list of re-started stores and check if BO is up for all stores that were restarted
echo "STEP 5.  Check if BO is successfully restarted." >> $LOG
if [[ -s $RESTARTEDSTORES ]];then echo "Sleeping for 2.5 minutes to allow BO to start up"; sleep 150; fi

for LINE in `cat $RESTARTEDSTORES`
do
    STORE=`echo $LINE | cut -d'|' -f1`
    SERVER=`echo $LINE | cut -d'|' -f2`
    echo "Checking BO is up for store $STORE" >> $LOG
    chkIfServerUp
    serverUp=$?
    if [[ $serverUp -eq 0 ]];then
        echo "ERROR: $STORE - BO start failed." >> $ERRLOG
    else
        echo "$STORE successfully updated." >> $OK_LOG
    fi
done
echo "----------------- END STEP 5" >> $LOG


## Generate results summary and display to screen
egrep 'ERROR.*scp failed|ERROR.*BO start failed|ERROR.*manually deploy the cert|ERROR.*Unable to ssh .* for a 2nd time' $ERRLOG | sed 's#^ERROR: \(.*\)$#\1#' >> $FAILED_STORES
fail_cnt=`wc -l $FAILED_STORES | awk '{print $1}'`

echo "" >> $RESULT_SUMRY
echo "" >> $RESULT_SUMRY
echo "" >> $RESULT_SUMRY
echo "==========================" >> $RESULT_SUMRY
echo "SUMMARY OF SSL CERT UPDATE" >> $RESULT_SUMRY
echo "==========================" >> $RESULT_SUMRY
echo "" >> $RESULT_SUMRY
if [[ $fail_cnt -gt 0 ]];then
    echo "Stores that failed ssl cert update (count of $fail_cnt) is shown below:" >> $RESULT_SUMRY
    echo "===============================================================" >> $RESULT_SUMRY
    cat $FAILED_STORES >> $RESULT_SUMRY
else
    echo "None of the stores failed the ssl cert update." >> $RESULT_SUMRY
fi
echo "" >> $RESULT_SUMRY
echo "----------------------------------------------------------------------" >> $RESULT_SUMRY
echo "" >> $RESULT_SUMRY

ok_cnt=`wc -l $OK_LOG | awk '{print $1}'`
if [[ $ok_cnt -gt 0 ]];then
    echo "Stores that succeeded the ssl cert update (count of $ok_cnt) is shown below:" >> $RESULT_SUMRY
    echo "======================================================================" >> $RESULT_SUMRY
    cat $OK_LOG >> $RESULT_SUMRY
else
    echo "None of the stores succeeded the ssl cert update." >> $RESULT_SUMRY
fi

echo "" >> $RESULT_SUMRY
cat $RESULT_SUMRY


## Cleanup working files
if [[ $fail_cnt -eq 0 ]]; then rm $LOOP2LIST $RESTARTEDSTORES $START_STOP_OUTPUT; fi


