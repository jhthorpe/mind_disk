#!/bin/bash
# mind_disk.sh
#   JHT, May/June 2022 : created
#
# A collection of functions that support the following primary functions that
#   can be used in a slurm script:
#
#   md_start
#   md_exec
#   md_end
#   md_kill
#
# md_start sets up the quota, finds some cahced variables, and 
#   creates the local mdquota.txt file, which records the quota desired 
#   for this script  
#
# The following variables are initialized and/or used 
#   by this script
#
#   MD_THISQUOTA    : passed as an arguement into md_start,
#                     this value marks the max amount of disk (measured
#                     by du) that a directory can use. 
#
#   MD_THISDISK     : last measured value of disk usage (in GB) of 
#                     the current directory
#
#   MD_PATH         : enviroment variable that must be in place
#                     at the time of calling md_start. 
#                     Provides path to MD directory
#
#   MD_FILE         : generated from MD_PATH in md_start,
#                     this is the path to the file that mind_disk uses
#                     to track resources (exported to eviroment)
#

#--------------------------------------------------------------------
# md_exec
#   JHT, June 2, 2022 : created
#
#   script to actively mind the disk usage generated by an 
#   input command. Check's an in put number of seconds if 
#   we have exceeded quota and updates the disk in $MD_FILE
#
#   INPUT:
#   $1  : command to execute
#   $2  : sleep timer in seconds
#
#   VARIABLES (need to be preset by md_start)
#   $MD_FILE        : file which this all queries
#   $MD_THISQUOTA   : disk quota for this job
#   $MD_THISDISK    : disk usage for this job so far
#
#--------------------------------------------------------------------
md_exec() {
  echo "@md_exec ($$)"
  local CMD=$1
  local INC=$2

  #just in case empty command
  if [ -z "$CMD" ]; then CMD="sleep 1"; fi
 
  #in case of empty inc
  if [ -z "$INC" ]; then INC=100; fi
  if (( $( bc -l <<< "$INC < 0" ) )); then
    INC=100
  fi

  #Start the command in the background
  $CMD &
  CMD_PID=$!
  CMD_STRT=$( get_pid_start_time "$CMD_PID" )

  #start the disk manager
  disk_manager "$INC" "$CMD_PID" "$CMD_STRT" &
  MD_PID=$!

  echo "command      : $CMD"
  echo "command pid  : $CMD_PID"
  echo "manager pid  : $MD_PID"

  wait #wait until everything is done
 
}


#--------------------------------------------------------------------
# md_start
#   JHT, May 31, 2022 : created
#
#   Sets up enviroment variables to mind_quota, which manages 
#     disk quota for jobs
#
#   INPUT VARIABLES
#   $1          : how much quota this job needs
#   $2          : command to execute on failure to satisfy quota
#
#   ENVIROMENT VARIABLES (need to be preset)
#   MD_PATH     : path to directory for MD files
#
#   OUTPUT VARIABLES
#   MD_DISKID   : used to identify the disk line in $MD_FILE
#   MD_FILE     : path to file which contains the quota info (enviro)
#   MD_THISQUOTA: quota needed for this disk
#
#--------------------------------------------------------------------
md_start() {
  echo "@md_start ($$)" 
  local FAIL_CMD=$2

  #initialize the THISQUOTA variable
  if [ -z "$1" ]; then 
    MD_THISQUOTA="0"
  else
    MD_THISQUOTA=$( proc_df "$1" ) 
  fi

  #initialize the diskid variable
  set_MD_DISKID
  
  #initialize the diskquota file
  init_MD_FILE

  #initialize the linenum
  set_MD_LINENUM

  #update the quota
  lock_file "-x -w 100" $MD_FILE 
  if [ $? == 0 ]; then
    update_quota $MD_THISQUOTA 
    if [ $? != 0 ]; then
      unlock_file $MD_FILE 
      $FAIL_CMD
      exit 1
    else
      unlock_file $MD_FILE
    fi
  else 
    echo "md_start could not lock $MD_FILE"
    exit 1
  fi

  #get current disk usage
  MD_THISDISK=$( get_THISDISK )
  lock_file "-x -w 100" $MD_FILE 
  if [ $? == 0 ]; then
    update_disk $MD_THISDISK
    if [ $? != 0 ]; then
      unlock_file $MD_FILE
      exit 1
    else 
      unlock_file $MD_FILE 
    fi
  else 
    echo "md_start could not lock $MD_FILE"
    exit 1
  fi

}

#--------------------------------------------------------------------
# mind_quota_end
#   JHT, June 1, 2022 : created
#
#   Unsets the quota updates final disk usage
#
#   ENVIROMENT VARIABLES (need to be preset)
#   MD_PATH     : path to directory for MD files
#   MD_THISQUOTA: quota needed for this disk
#   MD_DISKID   : used to identify the disk line in $MD_FILE
#   MD_FILE     : path to file which contains the quota info (enviro)
#
#--------------------------------------------------------------------
md_end() {
  echo "@md_end ($$)" 
  #check for empty THISQUOTA
  if [ -z "$MD_THISQUOTA" ]; then 
    MD_THISQUOTA="0"
  fi

  #update the quota
  MD_THISDISK=$( get_THISDISK )
  lock_file "-x -w 100" $MD_FILE 
  if [ $? == 0 ]; then
    update_disk $MD_THISDISK
    update_quota "-$MD_THISQUOTA" 
    unlock_file $MD_FILE 
  fi

  #finally, check for cleanup on this HOST
  md_cleanup

}

#--------------------------------------------------------------------
# md_cleanup
#   JHT, June 2, 2022 : created
#
#   Using $MD_DISKID, checks the group's slurm usage. If this node
#   is not currently in use, empty the quotas and disk in $MD_FILE
#   for this entry
#--------------------------------------------------------------------
md_cleanup() {
  #don't do cleanup on HOME,BLUE, or RED
  if [[ "$MD_DISKID" == "HOME" || "$MD_DISKID" == "BLUE" || "$MD_DISKID" == "RED" ]]; then
    return 0
  fi 

  #Check if compute node has any jobs
  JOBS=( $( squeue -A johnstanton -w "$MD_DISKID" -o "%.18i" | xargs ) )

  #if there are jobs to check on
  if [ $? == 0 ]; then
    NEWQUOTA=0
    NEWDISK=0
   
    len=${#JOBS[@]}
    for (( i=1; i<$len ; i++)); do
      if [ "${JOBS[$i]}" == "$SLURM_JOB_ID" ]; then continue; fi
      THATQUOTA=$( head -n 1 "/scratch/local/${JOBS[$i]}/mdquota.txt" )
      THATDISK=$( head -n 1 "/scratch/local/${JOBS[$i]}/mddisk.txt" ) 
      NEWQUOTA=$( bc -l <<< "$NEWQUOTA + $THATQUOTA" )
      NEWDISK=$( bc -l <<< "$NEWDISK + $THATDISK" )
    done

    lock_file "-x" $MD_FILE
    if [ $? == 0 ]; then
      set_quota_disk $NEWQUOTA $NEWDISK
      unlock_file $MD_FILE
    fi

  fi
  

  #go through jobs on node
  
#  #if this node doesn't have any jobs, clean it out 
#  if [ $? != 0 ]; then
#    echo "Node $MD_DISKID has no jobs, cleaning data" 
#    lock_file "-x -w 100" $MD_FILE 
#    if [ $? == 0 ]; then
#      reset_quota 
#      unlock_file $MD_FILE 
#    fi
#  fi

}

#--------------------------------------------------------------------
# md_kill
#   JHT, June 2, 2022 : created
#
#   command to execute on exit or kill 
#--------------------------------------------------------------------
md_kill() {
  md_end
  kill 0 
}

#--------------------------------------------------------------------
# disk_manager
#   JHT, May 27, 2022 : created
#
# Periodically (every INC seconds, first argument), checks the 
#   current disk usage and updates it
#   
#--------------------------------------------------------------------
disk_manager() {
  local INC=$1 #sleep time in seconds
  local PID=$2 #command PID
  local TME=$3 #original start time of PID

  counter=0
  maxcounter=$( bc -l <<< "2592000/$INC" ) #kill after 1 month

  while : 
  do
    #check if the job is finished
    if [ "$( get_pid_start_time $PID )" != "$TME" ]; then
      update_disk $MD_THISDISK
      return 0
    fi

    #check if we are out of disk
    # note that this will wait INC seconds, and then 
    # fail 
    lock_file "-x -w $INC" $MD_FILE

    #If we managed to get the lock
    if [ $? == 0 ]; then
      check_disk 
      unlock_file $MD_FILE 

      #counter. Cancel after 1 month 
      counter=$((counter+1))
      if (( $( bc -l <<< "$counter > $maxcounter") )); then
        kill -9 $PID
        exit 1
      fi
      # I'd ideally like to sleep the total amount of time we
      #  waited, rather than however long it took to get a lock
      #  plus the extra increment, but I haven't implemented that 
      sleep $INC

    #if we didn't get the lock, just increment counter and 
    #hope for next time. We will have waited $INC already, 
    # so just skip to next cycle
    else 
      #counter. Cancel after 1 month 
      counter=$((counter+1))
      if (( $( bc -l <<< "$counter > $maxcounter") )); then
        kill -9 $PID
        exit 1
      fi
    fi


  done
}

#--------------------------------------------------------------------
# update_quota
#   JHT, June 1, 2022 : created
#
#   Updates the quota in $MD_FILE for the current process.
#   Note that the file must be locked and unlocked before and
#   after this call
#
#   INPUT
#   $1  :   Quota to increment by   
#
#   ENVIROMENT (must be preset)
#   $MD_FILE : path to file to edit
#--------------------------------------------------------------------
update_quota(){
  local RES=$1

  #Get current line parameters
  STR=$( sed -n "$MD_LINENUM"p $MD_FILE | xargs )
  HOST=$( cut -f 1 -d ' ' <<< $STR )
  MDISK=$( cut -f 2 -d ' ' <<< $STR )
  QUOTA=$( cut -f 3 -d ' ' <<< $STR )
  DUSED=$( cut -f 4 -d ' ' <<< $STR )

  #check the quota
  NEWQUOTA=$( bc -l <<< "$QUOTA+$RES" ) 
  if (( $( bc -l <<< "$NEWQUOTA < 0") )); then NEWQUOTA=0; fi
  if (( $( bc -l <<< "$MDISK < $NEWQUOTA" ) )); then
    echo "ERROR ERROR ERROR"
    echo "There is insufficent disk on $HOST for quota"
    echo "MAXDISK : $MDISK"
    echo "MYQUOTA : $NEWQUOTA"
    return 1  
  fi

  echo $NEWQUOTA > mdquota.txt

  #update the line 
  sed -i "$MD_LINENUM"s/".*"/"$HOST $MDISK $NEWQUOTA $DUSED"/ $MD_FILE

}

#--------------------------------------------------------------------
# set_quota_disk
#   JHT, June 2, 2022 : created
#
#   Sets quota and disk in $MD_LINENUM without checking 
#     for going over disk or quota 
#
#   INPUT
#   $1  :   quota to input
#   $2  :   disk to input
#
#   ENVIROMENT (must be preset)
#   $MD_FILE    : path to file to edit
#   $MD_LINENUM : line number of this entry in $MD_FILE
#--------------------------------------------------------------------
set_quota_disk(){
  #Get current line parameters
  STR=$( sed -n "$MD_LINENUM"p $MD_FILE | xargs )
  HOST=$( cut -f 1 -d ' ' <<< $STR )
  MDISK=$( cut -f 2 -d ' ' <<< $STR )

  #update the line 
  sed -i "$MD_LINENUM"s/".*"/"$HOST $MDISK $1 $2"/ $MD_FILE

}

#--------------------------------------------------------------------
# update_disk
#   JHT, June 1, 2022 : created
#   
#   Determines current disk usage of directory, and updates the value 
#   in 
#
#   INPUT
#   $1  : old disk usage from get_THISDISK 
#
#   ENVIROMENT (must be preset)
#   $MD_FILE : path to file to edit
#--------------------------------------------------------------------
update_disk(){
  local OLDDISK=$1
  
  #Get current line parameters
  STR=$( sed -n "$MD_LINENUM"p $MD_FILE | xargs )
  HOST=$( cut -f 1 -d ' ' <<< $STR )
  MDISK=$( cut -f 2 -d ' ' <<< $STR )
  QUOTA=$( cut -f 3 -d ' ' <<< $STR )
  DUSED=$( cut -f 4 -d ' ' <<< $STR )

  #check if the current disk usage is above quota
  NEWDISK=$( get_THISDISK )
  if (( $( bc -l <<< "$MD_THISQUOTA < $NEWDISK" ) )); then
    unlock_file $MD_FILE 
    echo "ERROR ERROR ERROR"
    echo "This process has exceeded it's disk quota"
    echo "DISK USAGE: $NEWDISK"
    echo "QUOTA : $MD_THISQUOTA"
    return 1  
  fi

  #update values
  DUSED=$( bc -l <<< "$DUSED - $OLDDISK + $NEWDISK" )
  MD_THISDISK=$NEWDISK

  echo "$MD_THISDISK" > mddisk.txt

  #update the file
  sed -i "$MD_LINENUM"s/".*"/"$HOST $MDISK $QUOTA $DUSED"/ $MD_FILE

}

#--------------------------------------------------------------------
# check_disk 
#   JHT, June 2, 2022 : created
#   
#   Determines current disk usage of directory, checks we are 
#   below quota, updates MD_THISDISK
#
#   ENVIROMENT 
#--------------------------------------------------------------------
check_disk(){
  
  #check if the current disk usage is above quota
  MD_THISDISK=$( get_THISDISK )
  if (( $( bc -l <<< "$MD_THISQUOTA < $NEWDISK" ) )); then
    echo "ERROR ERROR ERROR"
    echo "This process has exceeded it's disk quota"
    echo "DISK USAGE: $MD_THISDISK"
    echo "QUOTA : $MD_THISQUOTA"
    exit 1  
  fi

  echo "$MD_THISDISK" > mddisk.txt

}


#--------------------------------------------------------------------
# proc_df
#   JHT, May 27, 2022 : created
#
# Processes a string of form XXXY, where XXX is a number string 
#   and Y is a string indicating the units (10.2T would be 10.2 TB, 
#   for example), and converts this value to GB. 
#
#   This is used by get_avl_disk and get_max_disk to determine
#   how much disk space is available on a filesystem.
#--------------------------------------------------------------------
proc_df() {
  local DISK=$1
  UNIT=${DISK: -1} #get unit character
  DISK=${DISK::-1} #trim unit character
  if [ "$UNIT" ==  "T" ]; then
    CONV="1000"
  elif [ "$UNIT" == "G" ]; then
    CONV="1"
  elif [ "$UNIT" == "P" ]; then
    CONV="1000000"
  elif [ "$UNIT" == "M" ]; then
    CONV="0.001"
  elif [ "$UNIT" == "K" ]; then
    CONV="0.000001"
  else
    echo "Bad unit in proc_df input" >&2
    exit 1;
  fi
  DISK=$( bc -l <<< "$CONV*$DISK" ) #adjust DISK to GB 
  echo "$DISK"
}

#--------------------------------------------------------------------
# get_avl_disk
#   JHT, May 27, 2022 : created
#
# Queries df -h . to obtain the current available disk in GB
#--------------------------------------------------------------------
get_avl_disk() {
  AVL_DISK=$( proc_df `df -h . | tail -1 |  xargs | cut -f 4 -d " "`)
  echo "$AVL_DISK"
}

#--------------------------------------------------------------------
# get_max_disk
#   JHT, May 27, 2022 : created
#
# Queries df -h . to obtain the current max disk in GB
#--------------------------------------------------------------------
get_max_disk() {
  MAX_DISK=$( proc_df `df -h . | tail -1 |  xargs | cut -f 2 -d " "`)
  echo "$MAX_DISK"
}

#--------------------------------------------------------------------
# get_THISDISK 
#   JHT, May 31, 2022 : created
#
#   queries du -hs . to determine the current disk usage of this
#   directory
#
#   NOTE : this *only* works if the files generated by the script
#           you call this with are containted within the directory
#           accessed by du -sh . 
#           
#--------------------------------------------------------------------
get_THISDISK () {
  echo "$( proc_df `du -sh . | xargs | cut -f 1 -d " " ` )"
}


#--------------------------------------------------------------------
# get_pid_start_time
#   JHT, May 27, 2022 : created
#  
# prints the start time of a particular process id (first arguement)
#
# note that if the file does not exist, it will return nothing, and
#   thus string comparison, not integer comparison, should be used
#--------------------------------------------------------------------
get_pid_start_time() {
  cut -d ' ' -f 22 /proc/$1/stat 2> /dev/null
}

#--------------------------------------------------------------------
# set_MD_DISKID
#   JHT, May 31, 2022 : created
#
#   initializes the MD_DISKID variable based on the host and 
#     mount point 
#--------------------------------------------------------------------
set_MD_DISKID() {

  #get host name
  HOST=$( cat /proc/sys/kernel/hostname )

  #get mount
  MOUNT=$( df -h . | tail -1 | xargs | cut -f 6 -d ' ' )

  echo "Host is $HOST"
  echo "Mount is $MOUNT"

  if [ "${MOUNT::3}" == "/sc" ]; then
    echo "This is scratch disk on tmpdir"
    MD_DISKID="${HOST::-6}"

  elif [ "${MOUNT::3}" == "/bl" ]; then
    echo "This is scratch disk on /blue"
    MD_DISKID="BLUE"

  elif [ "${MOUNT::3}" == "/re" ]; then
    echo "This is scratch disk on /red"
    MD_DISKID="RED"

  elif [ "${MOUNT::3}" == "/ho" ]; then
    MD_DISKID="HOME"

  else
    echo "ERROR ERROR ERROR"
    echo "Bad Mount or Host in set_MD_DISKID"
    exit 1

  fi

}

#--------------------------------------------------------------------
# set_MD_PATH
#   JHT, May 31, 2022 : created
#
# Initializes the MD_PATH if it doesn't exist 
#
# Note: this uses the MD_PATH enviromental variable
#--------------------------------------------------------------------
init_MD_FILE() {

  #check the quotafile enviromental variable exists and is not blank
  if [ -z "$MD_PATH" ]; then
    echo "ERROR ERROR ERROR"
    echo "MD_PATH is either unset, or set to an empty string"
    exit 1
  fi

  export MD_FILE="$MD_PATH/mdquota.txt"

  #check the file exists, and if not, exist it
  if [ ! -f "$MD_FILE" ]; then
    echo "$MD_FILE does not exist, creating"
    mkdir -p $MD_PATH
    echo "DISKID  MAXDISK  GQUOTA  GUSAGE" > $MD_FILE
  fi

}

#--------------------------------------------------------------------
# set_MD_LINENUM
#   JHT, May 31, 2022 : created
#
#   locates the line number of the MD_DISKID
#--------------------------------------------------------------------
set_MD_LINENUM() {

  MD_LINENUM=$( grep -n "$MD_DISKID" $MD_FILE | cut -f1 -d: )

  #if line is not found, add it to the file
  if [ -z "$MD_LINENUM" ]; then
    lock_file "-x" $MD_FILE
    MTMP1=$( get_max_disk )
    echo "$MD_DISKID $MTMP1 0 0" >> $MD_FILE
    MD_LINENUM=$( grep -n "$MD_DISKID" $MD_FILE | cut -f1 -d: )
    unlock_file $MD_FILE
  fi
}

#--------------------------------------------------------------------
# lock_file 
#   JHT, May 31, 2022 : created
#
#   Locks a file with the options provided by the first arguement
#     and the name given by the second arguement
#--------------------------------------------------------------------
lock_file(){
  exec 8>>$2
  flock $1 8
}

#--------------------------------------------------------------------
# unlock_file
#   JHT, May 31, 2022 : created
#
#   unlocks a file
#--------------------------------------------------------------------
unlock_file(){
  exec 8>>$1
  flock -u 8
}


