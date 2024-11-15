#!/bin/bash

# Check if machine_id is provided as an argument
if [ -z "$1" ]; then
  echo "Usage: $0 <machine_id>"
  exit 1
fi

MACHINE_ID=$1

# Get list of instances in raw format
INSTANCES=$(./vast show instances --raw)

# Extract IDs of machines with the specified machine_id and iterate over them
echo "$INSTANCES" | jq -r --arg MACHINE_ID "$MACHINE_ID" '.[] | select(.machine_id == ($MACHINE_ID | tonumber)) | .id' | while read -r ID; do
    echo "Destroying instance with ID: $ID (machine_id: $MACHINE_ID)"
    ./vast destroy instance "$ID"
done

