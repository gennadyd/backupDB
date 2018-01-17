#!/bin/bash

## ENV

ulimit -n 10000
# Get data in dd-mm-yyyy format
NOW="$(date +"%d-%m-%Y-%Hm%Ms%S")"

### SET ENV

MyUSER="myUser"     # USERNAME
MyPASS="myPaaswd"       # PASSWORD
MyPORT=$1 #PORT
MySocket="/var/lib/mysql/mysql$MyPORT.sock"
MyLogFile="/var/log/mysql$MyPORT.$NOW.log"
nfsServer="11.1.11.1"

exec > $MyLogFile 2>&1

# Linux bin paths, change this if it can not be autodetected via which command
MYSQL="$(which mysql)"
MYSQLDUMP="$(which mysqldump)"
CHOWN="$(which chown)"
CHMOD="$(which chmod)"
GZIP="$(which gzip)"


# Get hostname
HOST="$(hostname)"

INFO(){
        #print in green
        echo -e "\t \033[0;32m"$1"\033[0;0m"
}

ERROR(){
        #print in red
        echo -e "\t \033[0;31m"$1"\033[0;0m"
}

function sanity_checks() {
        INFO "sanity_checks function"

        INFO "CHECK IF $MySocket is exists"
        if [ ! -e "$MySocket" ]; then
                echo "$MySocket is not exits on $HOST" >> $MyLogFile
                exit 100 ;
        fi

        INFO "Get local directories"

        LDIR="/auto-backup"
        check_dir $LDIR

        # Get mount
        MOUNT="/mount-dir"
        if ! grep -qs '$MOUNT' /proc/mounts; then
                if [ ! -d "$MOUNT" ]; then
                        mkdir $MOUNT
                        echo "$MOUNT is not exist. creating.."
                fi
                mount ${nfsServer}:/backup $MOUNT
        fi

        # set local dest directory
        LDEST="$LDIR/$HOST/$MyPORT"
        check_dir $LDEST

        LBD="$LDEST/mysql"
        check_dir $LBD

        LXTRAN="$LDEST/xtranbackup"
        check_dir $LXTRAN

        LFILE="$LBD/$HOST.$NOW.xtra.tar.gz"

        INFO "GET mount dest directory"

        MDEST="$MOUNT/$HOST/$MyPORT"
        check_dir $MDEST

        MBD="$MDEST/mysql"
        check_dir $MBD

        MXTRAN="$MDEST/xtranbackup"
        check_dir $MXTRAN

        MFILE="$MBD/$HOST.$NOW.xtra.tar.gz"
        
}

function check_dir() {
        DIR=$1

        INFO "\tCHECK IF $DIR is exists"

        if [ ! -d $DIR ] ; then
                ERROR "\t\t$DIR doesn't exists. creating ... "
                mkdir -p $DIR
        fi
}

function is_db_slave() {

        INFO "\n----- is_db_slave function -----"
        Slave_IO_Running=`mysql --user=$MyUSER --socket=$MySocket --port=$MyPORT --password=$MyPASS -e'show slave status\G'| grep Slave_IO_Running | awk '{print $2}'`
        if [ $Slave_IO_Running == 'No' ]; then
                ERROR "$MySocket is not SLAVE"
                exit 300
        else
                INFO "IT'S SLAVE Slave_IO_Running : $Slave_IO_Running "
        fi
}

function delete_prev_backups() {
        INFO "delete_prev_backups function"
        DIR=$1
        if [ ! -d $DIR ] ; then
                ERROR "\t$DIR doesn't exists.  "
        else
                ERROR "\tdeleting previous backups under $DIR"
                rm -rf $DIR
        fi
}

function local_backup() {
        INFO "\n----- local_backup function -----"
        delete_prev_backups $LXTRAN/full/

        INFO "STOP SLAVE; SET GLOBAL slave_parallel_workers=0;START SLAVE "
        mysql --user=$MyUSER --socket=$MySocket --port=$MyPORT --password=$MyPASS -e'STOP SLAVE; SET GLOBAL slave_parallel_workers=0;START SLAVE;'
        INFO "running [innobackupex --slave-info --user=$MyUSER --socket=$MySocket --port=$MyPORT --password=$MyPASS --no-timestamp --use-memory=4G $LDEST/xtranbackup/full/]"
        /usr/bin/innobackupex --slave-info --user=$MyUSER --socket=$MySocket --port=$MyPORT --password=$MyPASS --no-timestamp --use-memory=4G $LDEST/xtranbackup/full/
        if [ ${PIPESTATUS[0]} -ne "0" ];
        then
                ERROR "the command \"innobackupex\" failed with Error: ${PIPESTATUS[0]}"
                exit 1;
        else
                INFO "running [innobackupex --apply-log --slave-info --user=$MyUSER --password=$MyPASS --use-memory=4G $LDEST/xtranbackup/full/]"
                /usr/bin/innobackupex --apply-log --slave-info --user=$MyUSER --password=$MyPASS --use-memory=4G $LDEST/xtranbackup/full/
                if [ ${PIPESTATUS[0]} -ne "0" ];
                then
                        ERROR "the command \"innobackupex\" failed with Error: ${PIPESTATUS[0]}"
                        exit 1;
                else
                        INFO "creating tar file [tar cv  --use-compress-program=pigz -f  $FILE $LDEST/xtranbackup/full/]"
                        tar  cv --use-compress-program=pigz -f $LFILE $LDEST/xtranbackup/full/
                        #tar cvfz $LFILE $LDEST/xtranbackup/full/
                        INFO "Database dump successfully!"
                fi
        fi
        INFO "STOP SLAVE; SET GLOBAL slave_parallel_workers=2;START SLAVE;"
        mysql --user=$MyUSER --socket=$MySocket --port=$MyPORT --password=$MyPASS -e'STOP SLAVE; SET GLOBAL slave_parallel_workers=2;START SLAVE;'
}

function backup_to_mount() {
        INFO "backup_to_mount function"
        #delete_prev_backups $MXTRAN/full/
        #INFO "\tmove $LXTRAN/full to $MXTRAN/full"
        # mv $LXTRAN/full $MXTRAN/full
        INFO "\tmove $LDEST/mysql/* to $MDEST/mysql/"
        mv $LDEST/mysql/* $MDEST/mysql/
        ERROR "\tfind and remove *.xtra.tar.gz files older 7 days under $MDEST/mysql/"
        find $MDEST/mysql/*.xtra.tar.gz -type f -mtime +7 | xargs rm -f
        delete_prev_backups /auto-backup
}

### MAIN
delete_prev_backups /auto-backup
sanity_checks
is_db_slave
local_backup
backup_to_mount
