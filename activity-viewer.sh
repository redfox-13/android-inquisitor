#!/bin/bash

PACKAGE_NAME=$1

if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: ./activity-viewer <package.name>"
    exit 1
fi

echo "Filtering Activities for $PACKAGE_NAME..."

# 1. Get dumpsys
DUMPSYS_DATA=$(adb shell dumpsys package "$PACKAGE_NAME")

# 2. Extract ONLY the Activity Resolver Table section, then find the class names
# This regex looks for the package/activity pattern only within the relevant block
mapfile -t ACTIVITIES < <(echo "$DUMPSYS_DATA" | \
    sed -n '/Activity Resolver Table:/,/Receiver Resolver Table:/p' | \
    grep -o "$PACKAGE_NAME/.[^ ]*" | \
    sed 's/[:}]//g' | \
    sort -u)

if [ ${#ACTIVITIES[@]} -eq 0 ]; then
    echo "No launchable Activities found."
    exit 1
fi

# 3. Clean Menu
echo "------------------------------------------------"
echo " VALID ACTIVITIES FOR: $PACKAGE_NAME"
echo "------------------------------------------------"
PS3="
Choose a screen to launch [1-${#ACTIVITIES[@]}]: "

select ACT in "${ACTIVITIES[@]}"; do
    if [ -n "$ACT" ]; then
        echo "Attempting to launch: $ACT"
        # -W waits for launch to complete and prints results
        adb shell am start -W -n "$ACT"
        break
    else
        echo "Invalid selection."
    fi
done
