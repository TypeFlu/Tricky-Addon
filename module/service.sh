MODPATH=${0%/*}
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
HIDE_DIR="/data/adb/modules/.TA_utl"
TS="/data/adb/modules/tricky_store"
TSPA="/data/adb/modules/tsupport-advance"

aapt() { "$MODPATH/common/aapt" "$@"; }

add_denylist_to_target() {
    exclamation_target=$(grep '!' "/data/adb/tricky_store/target.txt" | sed 's/!$//')
    question_target=$(grep '?' "/data/adb/tricky_store/target.txt" | sed 's/?$//')
    target=$(sed 's/[!?]$//' /data/adb/tricky_store/target.txt)
    denylist=$(magisk --denylist ls 2>/dev/null | awk -F'|' '{print $1}' | grep -v "isolated")
    
    printf "%s\n" "$target" "$denylist" | sort -u > "/data/adb/tricky_store/target.txt"

    for target in $exclamation_target; do
        sed -i "s/^$target$/$target!/" "/data/adb/tricky_store/target.txt"
    done

    for target in $question_target; do
        sed -i "s/^$target$/$target?/" "/data/adb/tricky_store/target.txt"
    done
}

resetprop_if_empty() {
    CURRENT=$(getprop "$1")
    [ -z "$CURRENT" ] && resetprop -n "$1" "$2"
}

# Spoof security patch
if [ -f "/data/adb/tricky_store/security_patch_auto_config" ]; then
    sh "$MODPATH/common/get_extra.sh" --security-patch
fi

# Reset vbmeta related prop
if [ -f "/data/adb/boot_hash" ]; then
    hash_value=$(grep -v '^#' "/data/adb/boot_hash" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -z "$hash_value" ] && rm -f /data/adb/boot_hash || resetprop -n ro.boot.vbmeta.digest "$hash_value"
fi
resetprop_if_empty "ro.boot.vbmeta.device_state" "locked"
resetprop_if_empty "ro.boot.vbmeta.invalidate_on_error" "yes"
resetprop_if_empty "ro.boot.vbmeta.avb_version" "1.0"
resetprop_if_empty "ro.boot.vbmeta.hash_alg" "sha256"
vbmeta_size=$(busybox blockdev --getbsz "/dev/block/by-name/vbmeta$(getprop ro.boot.slot_suffix)")
[ -n "$vbmeta_size" ] || vbmeta_size="4096"
resetprop_if_empty "ro.boot.vbmeta.size" "$vbmeta_size"

# Disable TSupport-A auto update target to prevent overwrite
if [ -d "$TSPA" ]; then
    touch "/storage/emulated/0/stop-tspa-auto-target"
elif [ ! -d "$TSPA" ] && [ -f "/storage/emulated/0/stop-tspa-auto-target" ]; then
    rm -f "/storage/emulated/0/stop-tspa-auto-target"
fi

# Magisk operation
if [ -f "$MODPATH/action.sh" ]; then
    # Hide module from Magisk manager
    if [ "$MODPATH" != "$HIDE_DIR" ]; then
        rm -rf "$HIDE_DIR"
        mkdir -p "$HIDE_DIR"
        busybox chcon --reference="$MODPATH" "$HIDE_DIR"
        cp -af "$MODPATH/." "$HIDE_DIR/"
    fi
    MODPATH="$HIDE_DIR"

    # Add target from denylist
    # To trigger this, choose "Select from DenyList" in WebUI once
    [ -f "/data/adb/tricky_store/target_from_denylist" ] && add_denylist_to_target
else
    [ -d "$HIDE_DIR" ] && rm -rf "$HIDE_DIR"
fi

# Hide module from APatch, KernelSU, KSUWebUIStandalone, MMRL
rm -f "$MODPATH/module.prop"

# Symlink tricky store
if [ -f "$MODPATH/action.sh" ] && [ ! -e "$TS/action.sh" ]; then
    ln -s "$MODPATH/action.sh" "$TS/action.sh"
fi
if [ ! -e "$TS/webroot" ]; then
    ln -s "$MODPATH/webui" "$TS/webroot"
fi

# Optimization
OUTPUT_APP="$MODPATH/webui/applist.json"
OUTPUT_SKIP="$MODPATH/common/tmp/skiplist"
OUTPUT_XPOSED="$MODPATH/common/tmp/xposed"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# Create temporary directory
mkdir -p "$MODPATH/common/tmp"

# Additional system apps
if [ -f "/data/adb/tricky_store/system_app" ]; then
    SYSTEM_APP=$(cat "/data/adb/tricky_store/system_app" | tr '\n' '|' | sed 's/|*$//')
else
    SYSTEM_APP=""
fi

# Initialize cache files to save app list and skip list
echo "[" > "$OUTPUT_APP"
echo "# This file is generated from service.sh to speed up load time" > "$OUTPUT_SKIP"

# Get list of third party apps and specific system apps, then cache app name
# Check Xposed module
{ 
    pm list packages -3 | awk -F: '{print $2}' 2>/dev/null
    pm list packages -s | awk -F: '{print $2}' | grep -Ex "$SYSTEM_APP" 2>/dev/null || true
} | while read -r PACKAGE; do
    # Get APK path for the package
    APK_PATH=$(pm path "$PACKAGE" 2>/dev/null | head -n1 | awk -F: '{print $2}')
    APP_NAME=$(aapt dump badging "$APK_PATH" 2>/dev/null | grep "application-label:" | sed "s/application-label://g; s/'//g" | tr '\n' '')
    [ -z "$APP_NAME" ] && APP_NAME="$PACKAGE"
    echo "  {\"app_name\": \"$APP_NAME\", \"package_name\": \"$PACKAGE\"}," >> "$OUTPUT_APP"

    # Check if app is Xposed module and add to skip list if not
    touch "$OUTPUT_XPOSED"
    if aapt dump xmltree "$APK_PATH" AndroidManifest.xml 2>/dev/null | grep -qE "xposed.category|xposeddescription"; then
        echo "$PACKAGE" >> "$OUTPUT_XPOSED"
    else
        echo "$PACKAGE" >> "$OUTPUT_SKIP"
    fi
done

sed -i '$ s/,$//' "$OUTPUT_APP"
echo "]" >> "$OUTPUT_APP"

[ -f "$MODPATH/action.sh" ] && rm -rf "/data/adb/modules/TA_utl"
