#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
#
# This file is part of Overpass_API.
#
# Overpass_API is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# Overpass_API is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Overpass_API. If not, see <https://www.gnu.org/licenses/>.

# Runs every test in input/regression_*/. A test is a directory with
#
#   stdin.log    the query; for a CGI test, the request body, if any
#   init.osm     optional: data to import into a database of its own
#   import.args  optional: arguments for update_database (default: --meta)
#   env          optional: makes it a test of cgi-bin/interpreter, run with
#                these environment variables (one NAME=value per line)
#
# and its expected output in expected/regression_*/stdout.log and stderr.log.
# Without env, the query runs with osm3s_query. Version numbers in the output
# are replaced by "Overpass API".

BASEDIR="$(cd "$(dirname "$0")" && pwd)/.."
# A test of a hang must fail rather than block the suite or fill the disk:
# each test runs for at most TIMEOUT seconds and writes at most MAX_FILE_KB
# per file.
TIMEOUT=60
MAX_FILE_KB=10240

evaluate_test()
{
  local DIRNAME="$1" FILE RES

  FAILED=
  for FILE in "../../expected/$DIRNAME"/*; do
  {
    FILE="$(basename "$FILE")"
    if [[ ! -f $FILE ]]; then
    {
      echo "In Test $DIRNAME: Expected file \"$FILE\" doesn't exist."
      FAILED=YES
    }; fi
  }; done
  for FILE in *; do
  {
    [[ -e $FILE ]] || continue
    if [[ ! -f "../../expected/$DIRNAME/$FILE" ]]; then
    {
      echo "In Test $DIRNAME: Unexpected file \"$FILE\" exists."
      FAILED=YES
    }; else
    {
      RES="$(diff -q "../../expected/$DIRNAME/$FILE" "$FILE")"
      if [[ -n $RES ]]; then
      {
        echo "$RES"
        FAILED=YES
      }; fi
    }; fi
  }; done
};

perform_regression_test()
{
  local NAME="$1"
  local INPUT="../../input/$NAME"
  local STDIN DB_DIR RC LINE
  local DB_ARGS=() IMPORT_ARGS=() ENV_VARS=()

  mkdir -p "run/$NAME"
  pushd "run/$NAME/" >/dev/null || return
  rm -fR ./*

  STDIN="$INPUT/stdin.log"
  if [[ ! -f $STDIN ]]; then
    STDIN=/dev/null
  fi

  # The database lives in a short temporary path: the dispatcher's socket is
  # created in it, and socket paths are limited to about 100 characters.
  DB_DIR=
  if [[ -f "$INPUT/init.osm" ]]; then
  {
    DB_DIR="$(mktemp -d)"
    IMPORT_ARGS=(--meta)
    if [[ -f "$INPUT/import.args" ]]; then
      read -r -a IMPORT_ARGS <"$INPUT/import.args"
    fi
    "$BASEDIR/bin/update_database" --db-dir="$DB_DIR/" "${IMPORT_ARGS[@]}" --version=mock-up-init \
        <"$INPUT/init.osm" >/dev/null 2>&1
    DB_ARGS=(--db-dir="$DB_DIR/")
  }; fi

  if [[ -f "$INPUT/env" ]]; then
  {
    if [[ -n $DB_DIR ]]; then
    {
      local DISPATCHER_META="--meta"
      if [[ " ${IMPORT_ARGS[*]} " == *" --keep-attic "* ]]; then
        DISPATCHER_META="--attic"
      fi
      "$BASEDIR/bin/dispatcher" --osm-base "$DISPATCHER_META" "${DB_ARGS[@]}" &
      sleep 1
    }; fi
    while IFS= read -r LINE || [[ -n $LINE ]]; do
      [[ -n $LINE ]] && ENV_VARS+=("$LINE")
    done <"$INPUT/env"
    ( ulimit -f "$MAX_FILE_KB"
      env -i PATH="$PATH" "${ENV_VARS[@]}" timeout "$TIMEOUT" "$BASEDIR/cgi-bin/interpreter" \
          <"$STDIN" >stdout.log 2>stderr.log )
    RC=$?
    if [[ -n $DB_DIR ]]; then
      "$BASEDIR/bin/dispatcher" --osm-base --terminate
    fi
  }; else
  {
    ( ulimit -f "$MAX_FILE_KB"
      timeout "$TIMEOUT" "$BASEDIR/bin/osm3s_query" "${DB_ARGS[@]}" \
          <"$STDIN" >stdout.log 2>stderr.log )
    RC=$?
  }; fi
  if [[ $RC -eq 124 ]]; then
    echo "Timed out after $TIMEOUT seconds." >>stderr.log
  elif [[ $RC -eq 153 ]]; then
    printf '\nStopped after writing %s KB to one file.\n' "$MAX_FILE_KB" >>stderr.log
  fi
  sed -i 's/Overpass API [^ ]* [a-f0-9]*\([" ]\)/Overpass API\1/g' stdout.log

  evaluate_test "$NAME"
  if [[ -n $FAILED ]]; then
  {
    echo "$(date +%T) Test $NAME FAILED."
  }; else
  {
    echo "$(date +%T) Test $NAME succeeded."
    rm -fR ./*
  }; fi
  if [[ -n $DB_DIR ]]; then
    rm -fR "$DB_DIR"
  fi
  popd >/dev/null || return
};

date +%T
for DIR in input/regression_*/; do
{
  [[ -d $DIR ]] || continue
  perform_regression_test "$(basename "$DIR")"
}; done
