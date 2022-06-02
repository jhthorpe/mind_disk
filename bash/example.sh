#!/bin/bash
#
#   Example of how to use mind_disk bash exectuables

my_command () {
  echo "I have been called"  
  echo "might consider resubmitting the job here"
}

another_command() {
  echo "this one got called, too"
  sleep 1
}

cd $SLURM_TMPDIR

#-----------------------------------------------------------------------
# STEP 1. Source files, setup enviroment, and initialize trap
#
# The trap manages a gracefull exit from the md enviroment, and 
#   calls md_kill, which does some cleanup to help prevent accumulative
#   errors from jobs that never got erased 
#
#   MD_PATH is an enviroment variable that points to the directory 
#   where mind_disk can generate temporary files
source ~james.thorpe/scripts/mind_disk/mind_disk.sh; trap md_kill EXIT
export MD_PATH=~james.thorpe/mdquota

#-----------------------------------------------------------------------
# STEP 2. initialize the md enviroment. 
#
# First input is the amount of quota we want to reserve for this disk
#   units are K, M, G, T, or P
#
# Second input is an optional command to execute if the disk quota cannot
#   be met 
md_start "100G" my_command

#-----------------------------------------------------------------------
# STEP 3. execute commands 
#
# option 1 is a command to executre
# option 2 is the number of seconds to check our disk usage
#
# This will execute your given command, and check the disk
# usage every given number of seconds to see if you are going over,
# in which case it will exit and call md_kill
md_exec "sleep 1" 2
md_exec another_command 1
