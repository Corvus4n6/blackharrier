#!/bin/bash
# check users to see if passwords are set and notify to prevent sadness
# 'L' means locked and 'NP' no password. 'P' means password set
CURRUSERNAME=`whoami`
CURRUSER=`passwd --status | awk '{ print $2 }'`
ROOTUSER=`sudo passwd --status | awk '{ print $2 }'`
NOTIFY="0"
NOTIFICATION=""

if [ "$CURRUSER" != "P" ]; then
    NOTIFICATION+="There is no password set for the ${CURRUSERNAME} user account. It is recommended that you set a password to prevent being locked out of the system or unable to perform certain tasks. To set your password, open the terminal and enter:\n\n \tsudo passwd ${CURRUSERNAME}\n\n"
    NOTIFY="1"
fi

if [ "$ROOTUSER" != "P" ]; then
    NOTIFICATION+="There is no password set for the root user account. It is recommended that you set a password to enable the full functionality of this system. To set the root password, open the terminal and enter:\n\n\tsudo passwd"
    NOTIFY="1"
fi

if [ "$NOTIFY" == "1" ]; then
    NOTIFICATIONFMT=`printf "${NOTIFICATION}" | fold -s -w80 -`
    zenity --warning --title="WARNING: Password Not Set" --text="${NOTIFICATIONFMT}" 2> /dev/null
fi
