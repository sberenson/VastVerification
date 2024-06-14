#!/bin/bash

# Function to check the status of an instance
function is_instance {
  id=$1
  retry_count=0
  max_retries=3

  while [ $retry_count -lt $max_retries ]; do
    # Run the command to get the instance details
    json_output=$(./vast show instance "$id" --raw 2>/dev/null)

    # Check the return status of the command
    if [ $? -eq 0 ]; then
      # Break the loop if command is successful
      break
    fi

    # Increment the retry count
    ((retry_count++))

    # If we've exhausted our retries, exit
    if [ $retry_count -eq $max_retries ]; then
      echo "unknown"
      return
    fi
  done

  # Parse the intended status from the JSON output
  intended_status=$(echo "$json_output" | jq -r '.intended_status // "unknown"')

  case $intended_status in
    "running")
      echo "running"
      ;;
    "offline")
      echo "offline"
      ;;
    "exited")
      echo "exited"
      ;;
    "unknown")
      echo "unknown"
      ;;
    "created")
      echo "created"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Get the IP and port from command line arguments
IP=$1
PORT=$2
instances_id=$3
machine_id=$4

# Check if four arguments were provided
if [ "$#" -ne 4 ]; then
    echo "Usage: ./machinetester.sh <IP> <Port> <instances_id> <machine_id>"
    echo "$machine_id:$instances_id usage error " >> Error_testresults.log
    exit 1
fi

# Generate a unique lock file name based on the parameters
lock_file="/tmp/machine_tester_locks_second/lock_${IP}_${PORT}_${instances_id}_${machine_id}"
mkdir -p "/tmp/machine_tester_locks_second"

# Attempt to acquire the lock
if flock -n "$lock_file" -c "true"; then
    SECONDS=0  # reset the SECONDS counter
    no_response_seconds=0  # Track how long there has been no response

    while [ $SECONDS -lt 300 ]; do
        # Check if script has been running for longer than 5 minutes
        if [ $SECONDS -gt 300 ]; then
            echo "$machine_id:$instances_id Time out while stress testing " >> Error_testresults.log
            ./vast destroy instance  $instances_id
            exit 1
        fi

        # Send an 'EOT' message and receive response
        message=$(echo "EOT" | nc -w 5 $IP $PORT)

        # If the message is 'DONE' or starts with 'ERROR', exit the loop
        if [[ "$message" == "DONE" ]]; then
            echo "$machine_id" >> Pass_testresults.log
            ./vast destroy instance  $instances_id
            exit 1
            break
        elif [[ "$message" == ERROR* ]]; then
            echo "$machine_id:$instances_id $message" >> Error_testresults.log
            ./vast destroy instance  $instances_id
            exit 1
            break
        fi

        # If no response is received, increment the no_response_seconds counter
        if [ -z "$message" ]; then
            ((no_response_seconds+=60))
        else
            no_response_seconds=0  # Reset if a response is received
        fi

        # If no response for 60 seconds and instance is still running, log the fault and exit
        if [ $no_response_seconds -ge 60 ]; then
            status=$(is_instance "$instances_id")
            if [ "$status" == "running" ]; then
                echo "$machine_id:$instances_id No response from port $PORT for 60s with running instance" >> Error_testresults.log
                ./vast destroy instance "$instances_id"
                exit 1
            fi
        fi

        # Wait for 20 seconds before the next iteration
        sleep 20
    done

    # Destroy the instance after the loop completes if it was running
    ./vast destroy instance "$instances_id"

    # Remove the lock file
    rm "$lock_file"
else
    echo "Lock file exists. Exiting..."
    echo "$machine_id:$instances_id Lock file exists. Exiting... " >> Error_testresults.log
    exit 1
fi

echo "Machine: $machine_id Done with testing remote.sh results $message"
