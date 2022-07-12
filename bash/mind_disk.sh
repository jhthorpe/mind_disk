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
  echo "@md_exec($$)"
  local CMD=$1
  local INC=$2

  #just in case empty command
  if [ -z "$CMD" ]; then CMD="sleep 1"; fi
 
  #in case of empty inc
  if [ -z "$INC" ]; then INC=100; fi
  if (( $( bc -l <<< "$INC <= 0" ) )); then
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
# md_prune
#   JHT, June 7, 2022 : created
#
#   cleanup redundent lines in the $MD_FILE
#--------------------------------------------------------------------
md_prune() {
  echo "@md_prune ($$)"

  #check MD_FILE is good
  if [ -z "$MD_FILE" ]; then
    echo "@md_prune($$) MD_FILE variable was empty"
    return 1  
  fi
  
  #read in the file
  mapfile -t FILE < "$MD_FILE"
  if [ $? != 0 ]; then
    echo "@md_prune($$) error from mapfile"
  fi

  #go through the first arguement of each line. Check it against
  # the lines before it. If match, do not add this line to the good
  # line list
  GOODLINE=( )
  GOODARG=( )
  for (( i=0; i<${#FILE[@]}; i++ )); do
    FLAG=0
    ARG=$( echo "${FILE[$i]}" | xargs |  cut -f 1 -d " " )
    for (( j=0; j<${#GOODARG[@]}; j++ )); do
#JHT extra printing here
      if [ $ARG == ${GOODARG[$j]} ]; then FLAG=1; echo "$ARG is repeated"; break; fi 
#      if [ "$ARG" == "${GOODARG[$j]}" ]; then FLAG=1; break; fi 
    done
    if [ $FLAG == 0 ]; then
      GOODARG+=("$ARG")
      GOODLINE+=("$i")
    fi
  done

  #write out the good lines to the file
  echo -n "" > $MD_FILE
  for line in ${GOODLINE[@]}; do
    echo "${FILE[$line]}" >> $MD_FILE 
  done

  echo "JHT PRINTING MD_FILE... SORRY"
  cat $MD_FILE

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
  echo "@md_start($$)" 
  local FAIL_CMD=$2

  #initialize the THISQUOTA variable
  if [ -z "$1" ]; then 
    MD_THISQUOTA="0"
  else
    MD_THISQUOTA=$( proc_df "$1" ) 
  fi
  if [ ! $( is_int $MD_THISQUOTA ) ]; then
    echo "@md_start($$) bad MD_THISQUOTA"
    exit 1
  fi 

  #check the quotafile enviromental variable exists and is not blank
  if [ -z "$MD_PATH" ]; then
    echo "ERROR ERROR ERROR"
    echo "MD_PATH is either unset, or set to an empty string"
    exit 1
  fi
  export MD_FILE="$MD_PATH/mdquota.txt"

  #initialize the diskid variable
  set_MD_DISKID
  if [ $? != 0 ]; then
    echo "@md_start($$) bad output from set_MD_DISKID"
    exit 1
  fi

  #get maxdisk variable
  MD_MAXDISK=$( get_max_disk )
  
  #initialize the diskquota file
  lock_file "-x -w 100" $MD_FILE 
  if [ $? == 0 ]; then

    #initialize the file if needed
    init_MD_FILE
    if [ $? != 0 ]; then 
      echo "@md_start($$) bad output from md_init_MD_FILE"
      exit 1
    fi

    #get line number for this host
    set_MD_LINENUM
    if [ $? != 0 ]; then 
      echo "@md_start($$) bad output from md_set_MD_LINENUM"
      exit 1
    fi

    #check if the line has the correct number of args
    md_checkline
    if [ $? != 0 ]; then 
      echo "@md_start($$) bad output from md_checkline"
      exit 1
    fi

    #if there are no active jobs except this one, cleanup quota
    md_cleanup 
    if [ $? != 0 ]; then
      echo "@md_start($$) bad output from md_cleanup"
      exit 1
    fi

    #update the quota
    update_quota $MD_THISQUOTA 
    if [ $? != 0 ]; then
      unlock_file $MD_FILE 
      echo "@mg_start($$) md_update_quota exited with error"
      $FAIL_CMD
      exit 1
    fi

    unlock_file $MD_FILE

  else 
    echo "@md_start($$) md_start could not lock $MD_FILE"
    exit 1
  fi

  check_disk 
  if [ $? != 0 ]; then
    echo "@md_start($$) Could not update disk"
    exit
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
  echo "@md_end($$)" 
  #check for empty THISQUOTA
  if [ -z "$MD_THISQUOTA" ]; then 
    MD_THISQUOTA="0"
  fi

  #if $MD_FILE is empty, exit
  if [ -z "$MD_FILE" ]; then
    return 1
  fi
  if [ ! $( is_int $MD_THISQUOTA ) ]; then
    echo "@md_start($$) bad MD_THISQUOTA"
    return 1
  fi 

  #if the file exists, do end update
  if [ -f "$MD_FILE" ]; then

    #update the quota
    lock_file "-x -w 100" $MD_FILE 
    if [ $? == 0 ]; then

      #get line number to update
      set_MD_LINENUM
      if [ $? != 0 ]; then
        unlock_file $MD_FILE
        return 1
      fi
 
      #update the quota
      update_quota "-$MD_THISQUOTA" 
      if [ $? != 0 ]; then
        echo "@md_end($$) update_quota failed "
        unlock_file $MD_FILE
        return 1
      fi

      #do cleanup on this host if no active jobs
      md_cleanup

      #finally, erase duplicate hosts in the file
      md_prune

      unlock_file $MD_FILE 
    fi

  else
    return 1
  fi
}

#--------------------------------------------------------------------
# md_cleanup
#   JHT, June 2, 2022 : created
#
#   Using $MD_DISKID, checks the group's slurm usage for a 
#   current node 
#
#   This assumes that the $MD_FILE has be locked prior to call
#--------------------------------------------------------------------
md_cleanup() {
  #don't do cleanup on HOME,BLUE, or RED
  if [[ "$MD_DISKID" == "HOME" || "$MD_DISKID" == "BLUE" || "$MD_DISKID" == "RED" ]]; then
    return 0
  fi 

  #check that $MD_FILE is valid
  if [ -z "$MD_FILE" ]; then return 1; fi

  #check that $MD_DISKID is valid
  if [ -z "$MD_DISKID" ]; then return 1; fi

  #check that $MD_LINENUM is valid
  if ( ! $( is_int $MD_LINENUM ) ); then return 1; fi

  #Check if compute node has any jobs
  JOBS=( $( squeue -A johnstanton -w "$MD_DISKID" -o "%.18i" | xargs ) )

  #if there are no active jobs on the node, clean this line
  if [ $? != 0 ]; then set_quota 0; return 0 ; fi
  
  #if there is only one active job, and that job is ours, set quota to zero
  if [ ${#JOBS[@]} == 2 ] && [ "${JOBS[1]}" == "$SLURM_JOB_ID" ]; then
    set_quota 0
    return 0
  fi 

}

#--------------------------------------------------------------------
# md_checkline
#   JHT, July 12, 2022 : created
#
#   Checks that the line in $MD_FILE has the right nubmer of arguements 
#--------------------------------------------------------------------
md_checkline() {
  #check that $MD_FILE is valid
  if [ -z "$MD_FILE" ]; then return 1; fi

  #check that $MD_DISKID is valid
  if [ -z "$MD_DISKID" ]; then return 1; fi

  #check that $MD_LINENUM is valid
  if ( ! $( is_int $MD_LINENUM ) ); then return 1; fi

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
      return 0
    fi

    #check if we are out of disk
    # this will call exit if we are out of disk
    check_disk 
    if [ $? != 0 ]; then
      echo "@md_disk_manager($$) md_check_disk failed"
      kill -9 $PID
      exit 1
    fi

    #counter. Cancel after 1 month 
    counter=$((counter+1))
    if (( $( bc -l <<< "$counter > $maxcounter") )); then
      kill -9 $PID
      exit 1
    fi

    #sleep until next check
    sleep $INC

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
  
  echo "@md_update_quota($$) updating quota in MD_FILE"

  if ( ! $(is_int $MD_LINENUM) ); then
    echo "@md_update_quota($$) LINENUM is not a number, $MD_LINENUM"
    return 1
  fi

  #Get current line parameters
  STR=$( sed -n "$MD_LINENUM"p $MD_FILE | xargs )
  if [ $? != 0 ]; then
    echo "@md_update_quota($$) bad arguments from line $MD_LINENUM in $MD_FILE"
    return 1 
  fi
  
  #check that we have 3 parameters
  NUM=`wc -w <<< "$STR"`
  if [ $NUM -ne 3 ]; then
    echo "@md_update_quota($$) Not enough variables on $MD_LINENUM in $MD_FILE"
    set_quota 0
    echo "@md_update_quota($$) Setting to 0 G and exiting"
    return 1
  fi
  

  #HOST=$( cut -f 1 -d ' ' <<< $STR )
  #MDISK=$( cut -f 2 -d ' ' <<< $STR )
  QUOTA=$( cut -f 3 -d ' ' <<< $STR )
  if [ $? -ne 0 ]; then
    echo "@md_update_quota($$) ERROR ERROR ERROR"
    echo "md_update_quota($$) could not cut third variable from line"
    return 1
  fi

  #check the quota
  NEWQUOTA=$( bc -l <<< "$QUOTA+$RES" ) 
  if (( $( bc -l <<< "$NEWQUOTA < 0") )); then NEWQUOTA=0; fi
  if (( $( bc -l <<< "$MD_MAXDISK < $NEWQUOTA" ) )); then
    echo "@md_update_quota($$) ERROR ERROR ERROR"
    echo "@md_update_quota($$) There is insufficent disk on $HOST for quota"
    echo "@md_update_quota($$) MAXDISK : $MD_MAXDISK"
    echo "@md_update_quota($$) MYQUOTA : $NEWQUOTA"
    return 1  
  fi

  #update the line 
  sed -i "$MD_LINENUM"s/".*"/"$MD_DISKID $MD_MAXDISK $NEWQUOTA"/ $MD_FILE

}

#--------------------------------------------------------------------
# set_quota
#   JHT, June 2, 2022 : created
#
#   Sets quota and disk in $MD_LINENUM without checking 
#     for going over disk or quota 
#
#   INPUT
#   $1  :   quota to input
#
#   ENVIROMENT (must be preset)
#   $MD_FILE    : path to file to edit
#   $MD_LINENUM : line number of this entry in $MD_FILE
#--------------------------------------------------------------------
set_quota(){
  
#  echo "@md_set_quota($$) linenum is $MD_LINENUM"

  #check for bad linenumber
  if ( ! $(is_int $MD_LINENUM) ); then
    echo "@md_update_quota($$) LINENUM is not a number, $MD_LINENUM"
    return 1
  fi

  #Get current line parameters
  STR=$( sed -n "$MD_LINENUM"p $MD_FILE | xargs )
  if [ $? != 0 ]; then
    echo "@md_set_quota($$) bad xargs from $MD_LINENUM in $MD_FILE"
    return 1
  fi
  #HOST=$( cut -f 1 -d ' ' <<< $STR )

  #update the line 
  sed -i "$MD_LINENUM"s/".*"/"$MD_DISKID $MD_MAXDISK $1"/ $MD_FILE

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
  if (( $( bc -l <<< "$MD_THISQUOTA < $MD_THISDISK" ) )); then
    echo "@md_check_disk($$) ERROR ERROR ERROR"
    echo "@md_check_disk($$) This process has exceeded it's disk quota"
    echo "@md_check_disk($$) DISK USAGE: $MD_THISDISK"
    echo "@md_check_disk($$) QUOTA : $MD_THISQUOTA"
    return 1    
  fi
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

  echo "DISK UNIT IS $UNIT" >&2

  #echo "JHT : UNIT IS $UNIT"
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
    echo "@md_proc_df($$) Bad unit in proc_df input" >&2
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
  if [ $? == 0 ]; then
    echo "$AVL_DISK"
  else 
    echo "@md_get_avl_disk($$) bad output from df"
    return 1
  fi
}

#--------------------------------------------------------------------
# get_max_disk
#   JHT, May 27, 2022 : created
#
# Queries df -h . to obtain the current max disk in GB
#--------------------------------------------------------------------
get_max_disk() {
  MAX_DISK=$( proc_df `df -h . | tail -1 |  xargs | cut -f 2 -d " "`)
  if [ $? == 0 ]; then
    echo "$MAX_DISK"
  else 
    echo "@md_get_max_disk($$) bad output from df"
    return 1
  fi
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
  THISDISK="$( proc_df `du -sh . | xargs | cut -f 1 -d " " ` )"
  if [ $? == 0 ]; then
    echo "$THISDISK"
  else 
    echo "@md_get_THISDISK($$) bad output from df"
    return 1
  fi
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
  if [ $? != 0 ]; then
    echo "@md_set_MD_DISKISK($$) bad mount point arguemnt"
    return 1
  fi

#  echo "@md_set_MD_DISKID($$) Host is $HOST"
#  echo "@md_set_MD_DISKID($$) Mount is $MOUNT"

  if [ "${MOUNT::3}" == "/sc" ]; then
    echo "@md_set_MD_DISKID($$) This is scratch disk on tmpdir"
    MD_DISKID="${HOST::-6}"

  elif [ "${MOUNT::3}" == "/bl" ]; then
    echo "@md_set_MD_DISKID($$) This is scratch disk on /blue"
    MD_DISKID="BLUE"

  elif [ "${MOUNT::3}" == "/re" ]; then
    echo "@md_set_MD_DISKID($$) This is scratch disk on /red"
    MD_DISKID="RED"

  elif [ "${MOUNT::3}" == "/ho" ]; then
    echo "@md_set_MD_DISKID($$) This is scratch disk on /home"
    MD_DISKID="HOME"

  else
    echo "@md_set_MD_DISKID($$) ERROR ERROR ERROR"
    echo "@md_set_MD_DISKID($$) Bad Mount or Host in set_MD_DISKID"
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

  #check the file exists, and if not, exist it
  if [ ! -f "$MD_FILE" ]; then
    echo "@md_init_MD_FILE($$) $MD_FILE does not exist, creating"
    mkdir -p $MD_PATH
#    echo "DISKID  MAXDISK  GQUOTA  GUSAGE" > $MD_FILE
  fi

}

#--------------------------------------------------------------------
# set_MD_LINENUM
#   JHT, May 31, 2022 : created
#
#   locates the line number of the MD_DISKID
#--------------------------------------------------------------------
set_MD_LINENUM() {

  MD_LINENUM=$( grep --text -m 1 -n "$MD_DISKID" $MD_FILE | cut -f1 -d: )

  echo "JHT LINENUM hello 1"


  #if line is not found, add it to the file
  if [ -z "$MD_LINENUM" ]; then
    MTMP1=$( get_max_disk )
    echo "$MD_DISKID $MTMP1 0" >> $MD_FILE
    MD_LINENUM=$( grep --text -m 1 -n "$MD_DISKID" $MD_FILE | cut -f1 -d: )
    echo "@md_set_MD_LINENUM($$) $MD_DISKID created on line $MD_LINENUM"
  else
    echo "@md_set_MD_LINENUM($$) $MD_DISKID found on line $MD_LINENUM"
  fi

  echo "JHT LINENUM hello 2"
  #check that LINENUM is actually a number
  if ( ! $( is_int $MD_LINENUM ) ); then
    echo "JHT LINENUM hello 3"
    echo "@md_set_MD_LINENUM($$) LINENUM is not a number: $MD_LINENUM"
    echo "The current state of MD_FILE is listed below"
    cat $MD_FILE
    return 1
  fi

  echo "JHT LINENUM last hello"
}

#--------------------------------------------------------------------
# lock_file 
#   JHT, May 31, 2022 : created
#
#   Locks a file with the options provided by the first arguement
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

#--------------------------------------------------------------------
# is_int
#   JHT, June 6, 2022 : created
#   
#   check that an input is an integer number
#--------------------------------------------------------------------
is_int() {
  re='^[0-9]+$'
  if ! [[ $1 =~ $re ]]; then
    return 1
  fi
  return 0
}

