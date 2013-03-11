#!/bin/sh
set -e

# Feel free to change any of the following variables for your app:
TIMEOUT=${TIMEOUT-60}
APP_NAME=blog
APP_ROOT=/home/deployer/apps/$APP_NAME

if [ -e "/tmp/unicorn.$APP_NAME.sock" ]; then
  PID=`lsof -t /tmp/unicorn.$APP_NAME.sock | head -1`
else
  PID=""
fi

CMD="cd $APP_ROOT; bundle exec unicorn -D -c $APP_ROOT/config/unicorn.rb -E production"
AS_USER=deployer
set -u

run () {
  if [ "$(id -un)" = "$AS_USER" ]; then
    eval $1
  else
    su -c "$1" - $AS_USER
  fi
}

case "$1" in
start)
  if [ -n "$PID" ] ;
  then
    echo >&2 "Already running" && exit 0
  fi
  run "$CMD"
  ;;
stop)
  kill -QUIT $PID && exit 0
  echo >&2 "Not running"
  ;;
force-stop)
  kill -TERM $PID && exit 0
  echo >&2 "Not running"
  ;;
restart|reload)
  kill -HUP $PID && echo reloaded OK && exit 0
  echo >&2 "Couldn't reload, starting '$CMD' instead"
  run "$CMD"
  ;;
*)
  echo >&2 "Usage: $0 <start|stop|restart|force-stop>"
  exit 1
  ;;
esac