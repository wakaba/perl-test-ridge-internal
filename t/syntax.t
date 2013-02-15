#!/bin/sh
echo "1..1"
rootdir=`dirname $0`/..
($rootdir/perl -c $rootdir/lib/Test/Ridge/Internal.pm && echo "ok 1") || echo "not ok 1"
