#!/bin/bash --noediting

##  Copyright (c) 2012 Red Hat, Inc. <http://www.redhat.com/>
##  This file is part of GlusterFS.
##
##  This file is licensed to you under your choice of the GNU Lesser
##  General Public License, version 3 or any later version (LGPLv3 or
##  later), or the GNU General Public License, version 2 (GPLv2), in all
##  cases as published by the Free Software Foundation.


MASTER=            # example, dp-prod-vol
SLAVESPEC=         # example, ssh://remote-host::dp-prod-vol-backup
MOUNT=/unreachable # will get reset in mount_client()
LOCAL_EXPORTS=     # will get set in gather_local_exports
VOLUMEID=

SLAVEHOST=        # extracted from $SLAVESPEC in parse_slave()
SLAVEVOL=         # extracted from $SLAVESPEC in parse_slave()
SLAVEMOUNT=       # mount via idler's cwd in /proc on slave
SLAVEPID=         # pid of slave idler

SSHKEY="/var/lib/glusterd/geo-replication/secret.pem"
MONITOR=          # pid of the monitor
MOUNT=            # /proc/$MONITOR/cwd

TAR_FROM_FUSE=no  # tar directly from backend or from FUSE mount?

HEARTBEAT_INTERVAL=30  # between idler on salve and master
PARALLEL_TARS=16   # maximum number of parallel transfers

shopt -s expand_aliases;

function msg()
{
    local datefmt="+%Y-%m-%d %H:%M:%S";
    local lvl=$1;
    shift;
    local line=$1;
    shift;
    echo "$@" | \
	(sed "s#\(.*\)#\[`date \"$datefmt\"`\] [`basename $0`:$line] $lvl: \1#" >&2)
}


function __fatal()
{
    msg FATAL "$@";
    exit 1
}


function __warn()
{
    msg WARNING "$@";
}


alias fatal='__fatal $LINENO';
alias warn='__warn $LINENO';


function stderr()
{
    echo "$@" >&2;
}


function usage()
{
    echo "Usage: $0 [options] <VOLNAME> <SLAVESPEC>"
    exit 1;
}


function SSHM()
{
    ssh -qi $SSHKEY \
	-oPasswordAuthentication=no \
	-oStrictHostKeyChecking=no \
	-oControlMaster=yes \
	-S $SLAVESOCK "$@";
}

function SSH()
{
    ssh -qi $SSHKEY \
	-oPasswordAuthentication=no \
	-oStrictHostKeyChecking=no \
	-oControlMaster=auto \
	-S $SLAVESOCK IDLER.IS.DEAD "$@";
}


function parse_master()
{
    local vol="$1";
    local status;

    status=$(gluster volume info $vol | grep Status: | cut -f2 -d:);
    [ "x$status" = "x" ] && fatal "unable to contact volume $vol";
    [ $status != "Started" ] && fatal "volume $vol is not start ($status)";

    MASTER=$vol

    VOLUMEID=$(gluster volume info $vol | grep 'Volume ID:' | cut -f3 -d' ');
    [ "x$VOLUMEID" = "x" ] && fatal "no volume ID for volume $MASTER";
}


function parse_slave()
{
    local slavespec="$1";
    local slave;
    local next;
    local host;

    slave=$(echo "$slavespec" | sed -nr 's#[^:]+://(.+:.+)#\1#p');
    SLAVEHOST=${slave/:*/};
    next=${slave/*:/};

    if [[ "$next" =~ .*/.* ]]; then
	SLAVEMOUNT=$next;
	echo "Slave path is $SLAVEMOUNT";
    else
	SLAVEVOL=$next;
	echo "Slave volume is $SLAVEVOL";
    fi

    [ "x$SLAVEHOST" = "x" ] && fatal "Invalid SLAVESPEC $1";
    [ "x$SLAVEVOL" = "x" -a "x$SLAVEMOUNT" = "x" ] && \
	fatal "Invalid SLAVESPEC $1";
}


function parse_cli()
{
    local go;

    go=$(getopt -- hi: "$@");
    [ $? -eq 0 ] || exit 1;

    eval set -- $go;

    while [ $# -gt 0 ]; do
	case "$1" in
	    (-h) usage;;
	    (-i) SSHKEY=$2; shift;;
	    (--) shift; break;;
	    (-*) stderr "$0: Unrecognized option $1"; usage;;
	    (*) echo "Passing $1" ; break;;
	esac
	shift;
    done

    [ $# -eq 2 ] || usage;

    MASTER="$1";
    SLAVESPEC="$2";

    parse_master "$MASTER";

    parse_slave "$SLAVESPEC";
}


function mount_client()
{
    local T; # temporary mount
    local i; # inode number

    T=$(mktemp -d);

    [ "x$T" = "x" ] && fatal "could not mktemp directory";

    [ -d "$T" ] || fatal "$T: not a directory";

    glusterfs -s localhost --volfile-id $MASTER --client-pid=-1 $T;

    i=$(stat -c '%i' $T);

    [ "x$i" = "x1" ] || fatal "could not mount volume $MASTER on $T";

    echo "Mounted volume $MASTER";

    cd $T;

    umount -l $T || fatal "could not umount $MASTER from $T";

    i=$(stat -c '%i' $T);

    [ "x$i" = "x1" ] && fatal "umount of $MASTER from $T failed?";

    rmdir $T || warn "rmdir of $T failed";

    MOUNT=/proc/$$/cwd/;
    MONITOR=$$;

    echo "Monitor PID is $MONITOR";
}


function resolve_ip()
{
    local host;

    host="$1";

    ping -c 1 -w 1 "$host" 2>/dev/null | \
	head -1 | \
	awk '{print $3}' | \
	sed 's/(\(.*\))/\1/g';
}


function is_host_local()
{
    local host;
    local ip;

    host="$1";
    ip=$(resolve_ip "$host");

    [ "x$ip" = "x" ] && return 1;

    ping -I "$ip" -w 1 -c 1 localhost >/dev/null 2>&1
}


function gather_local_exports()
{
    local bricks;
    local brick;
    local host;
    local dir;

    echo -n "Gathering local bricks ... "
    bricks=$(gluster volume info $MASTER | egrep 'Brick[0-9]+:' | cut -f2- -d:);
    for brick in $bricks; do
	host=${brick/:*/};
	dir=${brick/*:/};

	is_host_local $host && LOCAL_EXPORTS="$LOCAL_EXPORTS $dir";
    done

    echo $LOCAL_EXPORTS;

    if [ "x$LOCAL_EXPORTS" = "x" ]; then
	echo "No local exports. Bye.";
	exit 0;
    fi
}


function set_stime()
{
    local path="$1";
    local newstime="$2";

    if [ "$newstime" = 0 ]; then
	return;
    fi

    setfattr -h -n "trusted.glusterfs.$VOLUMEID.stime" -v "$newstime" "$path";
}


function get_sxtimes()
{
    local path="$1";
    local key;
    local out;

    _xtime=0;
    _stime=0;

    out=$(getfattr -h -e hex -d -m "trusted.glusterfs.$VOLUMEID.(s|x)time" "$path" 2>/dev/null);

    for l in $out; do
	if ! [[ $l =~ .*=.* ]] ; then
	    continue;
	fi

	key=${l/=*/};
	val=${l/*=/};

	if [ $key = "trusted.glusterfs.$VOLUMEID.xtime" ]; then
	    _xtime=$val;
	fi

	if [ $key = "trusted.glusterfs.$VOLUMEID.stime" ]; then
	    _stime=$val;
	fi
    done
}


function greater_than()
{
    local stime="$1"; # format 0x509026d0000ea0cd
    local ctime="$2"; # format 1351849326.0750226530
    local st_sec;
    local st_usec;
    local ct_sec;
    local ct_usec;
    local ct_usectmp;

    st_sec=${stime%????????};
    st_usec=0x${stime#??????????};

    ct_sec=${ctime/.*/};
    ct_usec=${ctime/*./};
    ct_usec=${ct_usec%0}; # strip one trailing 0 always

    ct_usectmp=${ct_usec#0};
    while [ "$ct_usectmp" != "$ct_usec" ]; do
	ct_usec=$ct_usectmp;
	ct_usectmp=${ct_usec#0};
    done

    if [[ $st_sec -ne $ct_sec ]]; then
	[[ $st_sec -gt $ct_sec ]];
	return $?
    fi

    [[ $st_usec -gt $ct_usec ]];
}


#
# @pending:
#
# Associative array with keys being directory paths and values being a triplets
# in the format "PENDING_COUNT XTIME_HEX STATUS"
#
# e.g "2 0x509026d0000ea0cd OK"
#     "1 0x339026d0000ea0cd ERR"
#
# When PENDING_COUNT reaches 0, depending on the STATUS either the xtime
# is written to disk as stime (if it is OK) or not, and also propagates
# "upwards" by decrementing the parent directory's PENDING_COUNT (and setting
# ERR if necessary)
#

declare -A pending;

#
# @BG_PIDS
#
# Array indexed by background PID and value the directory on which the
# background worker is processing
#

declare -A BG_PIDS;


function sync_files()
{
    trap 'kill $(jobs -p) 2>/dev/null' EXIT;

    local dir=$1;
    shift;
    local files="$@";
    if [ "x$TAR_FROM_FUSE" = "xyes" ]; then
	eval "tar --xattr -b 128 -C '$MOUNT/$PFX' -c $files" | \
	    SSH "tar -b 128 -C $SLAVEMOUNT/$PFX -x";
    else
	eval "tar -b 128 -C '$SCANDIR/$PFX' -c $files" | \
	    SSH "tar -b 128 -C $SLAVEMOUNT/$PFX -x";
    fi
}


function throttled_bg()
{
    while [ `jobs -pr | wc -l` -ge $PARALLEL_TARS ]; do
	echo "Throttling. Waiting for (`jobs -pr | wc -l` / $PARALLEL_TARS) jobs".
	# This is the point of application of "backpressure" from the WAN
	sleep 1;
    done

    "$@" &

    BG_PIDS[$!]="$PFX";
    pending_inc "$PFX";
}


function pending_set()
{
    local pfx;

    pfx="$1";

    pending[$pfx]="1 $2 OK";
}


function pending_inc()
{
    local val;
    local pfx;

    pfx="$1";

    val=${pending[$pfx]};
    set $val;
    pending[$pfx]="$(($1 + 1)) $2 $3";
}


function pending_done()
{
    local val;
    local cnt;
    local xtime;
    local pfx;
    local ppfx;
    local s;
    local status;

    pfx="$1";
    s="$2";

    val=${pending[$pfx]};

    if [ "x$val" = "x" ]; then
	echo "ERROR!! $pfx found NULL value!";
	exit 1;
    fi

    set $val;

    cnt=$1;
    xtime=$2;
    status=${s:-$3};

    cnt=$(($cnt - 1));

    pending[$pfx]="$cnt $xtime $status";

    if [ $cnt -eq 0 ]; then
	unset pending[$pfx];

	echo "$BASHPID Completed directory: $pfx ($status)";

	# propagate upwards
	if [ "$status" = "OK" ]; then
            # old xtime now becomes new stime, and will match new xtime if
            # no changes happened while we were crawling

	    set_stime "${SCANDIR}/$pfx" "$2";
	fi

	ppfx="${pfx%/*}";
	[ "$ppfx" = "$pfx" ] && return;

	pending_done "$ppfx" "$s";
    fi

}


function pending_dec()
{
    pending_done "$1" "";
}


function pending_err()
{
    pending_done "$1" "ERR";
}


function reap_bg()
{
    local jobspr;
    local j;
    local b;
    local s;
    local pfx;

    declare -A jobspr;

    for j in `jobs -pr`; do
	jobspr[$j]="r";
    done

    for b in ${!BG_PIDS[@]}; do
	if [ x${jobspr[$b]} = x ]; then
	    # this BG_PID is not running any more
	    wait $b;
	    s=$?;

	    pfx=${BG_PIDS[$b]};
	    unset BG_PIDS[$b];

	    if [ $s -eq 0 ]; then
		# successful remote untar
		pending_dec $pfx;
	    else
		# failed remote untar
		pending_err $pfx;
	    fi
	fi
    done
}


function crawl()
{
    local xtime; # xtime of master
    local stime; # xtime of slave (maintained on master's copy)
    local type;
    local name;
    local ctime;
    local files=; # shortlisted
    local dirs=; # shortlisted
    local d;
    local dir;
    local pfx;
    local size;
    local mode;
    local ppfx;

    dir="$1";
    pfx="$PFX";
    ppfx=${pfx%/*};

    get_sxtimes "$dir";

    xtime=$_xtime;
    stime=$_stime;

    if [ "$xtime" = "0" ]; then
	true
#	warn "missing xtime on $1";
#	return;
    fi
    # missing stime is 0 stime

    if [ "$xtime" = "$stime" ]; then
	true;
#	echo "$BASHPID Nothing to do: $pfx (x=$xtime,s=$stime)";
#	return 0;
    fi

    # always happens in pair:
    pending_set "$pfx" "$xtime";
    pending_inc "$ppfx";

    echo "$BASHPID Entering directory: $pfx (x=$xtime,s=$stime)";

    (cd "$dir"; find . -maxdepth 1 -mindepth 1 -printf "%y '%f' %s %#m %C@\n") > /tmp/xsync.$$.list

    while read line; do
	eval "set $line";
	type=$1;
	name=$2;
	size=$3;
	mode=$4;
	ctime=$5;

	[ "$name" = "." ] && continue;

	if [ "$dir" = "$SCANDIR" -a "$name" = ".glusterfs" ]; then
	    # Skipping internal .glusterfs
	    continue;
	fi

	if [ "$type" = "f" -a "$mode" = "0100" -a "$size" = "0" ]; then
	    # Skipping linkfile
	    continue;
	fi

	greater_than $stime $ctime && continue;

	if [ "$type" = "d" ]; then
	    if [ "x$dirs" = "x" ]; then
		dirs="$name";
	    else
		dirs="$dirs
$name";
	    fi
	else
	    files="$files '$name'";
	fi

    done < /tmp/xsync.$$.list;

    if [ "x$dirs" != "x" ]; then
	# in case directories are missing
	# use cpio to create just the directories without contents
	# (tar cannot do that)
	echo "$dirs" | (cd "$MOUNT/$PFX" && cpio --quiet --create) | \
	    SSH "cd $SLAVEMOUNT/$PFX && cpio --quiet --extract"
    fi

    if [ "x$files" != "x" ]; then
	## TODO check for false positives (xtime != ctime)
	## and add a doublecheck if necessary
	throttled_bg sync_files "$dir" "$files";
    fi

    if [ "x$dirs" != "x" ]; then
	for d in $dirs; do
	    [ "$d" = "." ] && continue

	    PFX="$pfx/$d";
	    crawl "$dir/$d";
	done
    fi

    pending_dec "$pfx";

    reap_bg;

    return 0;
}


function worker()
{
    SCANDIR="$1";
    PFX="."

    echo "Starting worker $BASHPID with monitor $MONITOR at $SCANDIR";
    trap 'kill $(jobs -p) 2>/dev/null' EXIT;

    while true; do
	sleep 1;
        # top level PFX _has_ to be "." for pending_{dec,err}() to work
	# it is assumed that if ${p%/*} = $p then we have reached top
	# of the tree.
	PFX=".";
	unset pending[*]; declare -A pending; # start fresh
	unset BG_PIDS[*]; declare -A BG_PIDS;

	crawl "${SCANDIR}";

	wait;

	reap_bg;
	if [ ${#BG_PIDS[*]} -ne 0 -o ${#pending[*]} -ne 0 ]; then
	    echo "!!!BUG!!! non empty pending/BG_PID at end of walk";
	    echo "Pending: ${!pending[*]}";
	    echo "BG_PIDS: ${!BG_PIDS[*]}";
	fi
    done
}


function idler()
{
    local cmd_line;

    cmd_line=$(cat <<EOF
function do_mount() {
v=\$1;
d=\$(mktemp -d 2>/dev/null);
glusterfs -s localhost --volfile-id \$v --client-pid=-1 -l /var/log/glusterfs/geo-replication-slaves/slave.log \$d;
cd \$d;
umount -l \$d;
rmdir \$d;
};
cd /tmp;
[ x$SLAVEVOL != x ] && do_mount $SLAVEVOL;
echo SLAVEPID \$BASHPID;
while true; do
    read -t $HEARTBEAT_INTERVAL pong || break;
    echo ping || break;
done
EOF
)
    echo "cmdline" >> /tmp/cmdline.log

    SSHM $SLAVEHOST bash -c "'$cmd_line'";
}


function keep_idler_busy()
{
    # there is no do/while loop :(
    local T=0;
    local i=0;
    local ping;
    local pong;

    while true; do
	echo ping >&${COPROC[1]} || break;
	read -t $HEARTBEAT_INTERVAL pong <&${COPROC[0]} || break;
	i=$(($i + 1));
	sleep 15;
    done

    echo "Failed at i=$i";
}


function set_slave_pid()
{
    local line;
    local pid;

    SLAVEPID=

    read line <&${COPROC[0]};

    SLAVEPID=$(echo $line | sed -n 's/^SLAVEPID //p');
}


function monitor()
{
    trap 'kill $(jobs -p) $BASHPID $COPROC_PID 2>/dev/null' EXIT;

    while true; do
	# re-evaluate $RAND for every generation
	SLAVESOCK=/tmp/xsync-$MONITOR-$RANDOM;

	echo "Starting idler via $SLAVESOCK for $SLAVEHOST:${SLAVEVOL:-$SLAVEMOUNT}";

	coproc idler;

	set_slave_pid;

	if [ "x$SLAVEPID" = "x" ]; then
	    echo "Could not establish connectivity with client";
	    kill $(jobs -p) 2>/dev/null;
	    wait;
	    echo "Cleanup done (sleep 60)";
	    sleep 60;
	    continue;
	fi

	SLAVEMOUNT=${SLAVEMOUNT:=/proc/$SLAVEPID/cwd};
	echo "Slave PID is $SLAVEPID. Path is $SLAVEMOUNT";

	for dir in $LOCAL_EXPORTS; do
	    worker $dir $SLAVEHOST $SLAVEMOUNT &
	    ## TODO: just for debugging have single worker
	    break;
	done

	keep_idler_busy;

	echo "Idler terimnated. Killing workers"

	kill $(jobs -p);

	wait;

	echo "Cleanup done (sleep 10)";
	sleep 10;
    done
}


function main()
{
    parse_cli "$@";

    gather_local_exports;

    mount_client;

    monitor;
}

main "$@";
