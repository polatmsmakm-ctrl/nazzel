# Xcode build-phase helpers that install the embedded Python runtime into the app.
#
# Adapted from Python.xcframework/build/utils.sh (CPython / BeeWare
# Python-Apple-support). The only change: frameworks are signed only when the
# build is actually signing (CI builds an unsigned IPA for sideloading, where the
# sideload tool re-signs everything).
#
# Usage in a Run Script phase:
#   set -e
#   source "$PROJECT_DIR/scripts/python_build_utils.sh"
#   install_python Python.xcframework app app_packages

install_stdlib() {
    PYTHON_XCFRAMEWORK_PATH=$1

    mkdir -p "$CODESIGNING_FOLDER_PATH/python/lib"
    if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
        echo "Installing Python modules for iOS Simulator"
        if [ -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/ios-arm64-simulator" ]; then
            SLICE_FOLDER="ios-arm64-simulator"
        else
            SLICE_FOLDER="ios-arm64_x86_64-simulator"
        fi
    elif [ "$EFFECTIVE_PLATFORM_NAME" = "-iphoneos" ]; then
        echo "Installing Python modules for iOS Device"
        SLICE_FOLDER="ios-arm64"
    else
        echo "Unsupported platform name $EFFECTIVE_PLATFORM_NAME"
        exit 1
    fi

    # Only one architecture per build (ARCHS=arm64).
    ARCH_NAME=$(echo "$ARCHS" | awk '{print $1}')

    if [ -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/lib" ]; then
        rsync -au --delete "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/lib/" "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
        rsync -au "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/lib-$ARCH_NAME/" "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
    else
        rsync -au --delete "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/lib/" "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
    fi
}

sign_framework() {
    FOLDER=$1
    if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        return 0
    fi
    echo "Signing framework as $EXPANDED_CODE_SIGN_IDENTITY_NAME ($EXPANDED_CODE_SIGN_IDENTITY)..."
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$FOLDER"
}

# Convert a single .so library into a framework that iOS can load.
install_dylib () {
    PYTHON_XCFRAMEWORK_PATH=$1
    INSTALL_BASE=$2
    FULL_EXT=$3

    EXT=$(basename "$FULL_EXT")
    MODULE_PATH=$(dirname "$FULL_EXT")
    MODULE_NAME=$(echo $EXT | cut -d "." -f 1)
    RELATIVE_EXT=${FULL_EXT#$CODESIGNING_FOLDER_PATH/}
    PYTHON_EXT=${RELATIVE_EXT/$INSTALL_BASE/}
    FULL_MODULE_NAME=$(echo $PYTHON_EXT | cut -d "." -f 1 | tr "/" ".");
    FRAMEWORK_BUNDLE_ID=$(echo $PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME | tr "_" "-")
    FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"

    if [ ! -d "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" ]; then
        mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
        cp "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/$PLATFORM_FAMILY_NAME-dylib-Info-template.plist" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    fi

    mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > ${FULL_EXT%.so}.fwork
    echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"

    if [ -e "$MODULE_PATH/$MODULE_NAME.xcprivacy" ]; then
        XCPRIVACY_FILE="$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/PrivacyInfo.xcprivacy"
        rm -rf "$XCPRIVACY_FILE"
        mv "$MODULE_PATH/$MODULE_NAME.xcprivacy" "$XCPRIVACY_FILE"
    fi

    sign_framework "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
}

process_dylibs () {
    PYTHON_XCFRAMEWORK_PATH=$1
    LIB_PATH=$2
    if [ ! -d "$CODESIGNING_FOLDER_PATH/$LIB_PATH" ]; then
        return 0
    fi
    find "$CODESIGNING_FOLDER_PATH/$LIB_PATH" -name "*.so" | while read FULL_EXT; do
        install_dylib $PYTHON_XCFRAMEWORK_PATH "$LIB_PATH/" "$FULL_EXT"
    done
}

install_python() {
    PYTHON_XCFRAMEWORK_PATH=$1
    shift

    install_stdlib $PYTHON_XCFRAMEWORK_PATH
    PYTHON_VER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | grep -E "^python3\.[0-9]+$")
    # Tests, IDLE and tkinter are dead weight on a phone.
    for junk in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data; do
        rm -rf "$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER/$junk"
    done
    DYNLOAD="$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER/lib-dynload"
    rm -f "$DYNLOAD"/_test*.so "$DYNLOAD"/_ctypes_test*.so "$DYNLOAD"/xx*.so "$DYNLOAD"/_xxtestfuzz*.so

    echo "Install Python $PYTHON_VER standard library extension modules..."
    process_dylibs $PYTHON_XCFRAMEWORK_PATH python/lib/$PYTHON_VER/lib-dynload

    for package_path in $@; do
        echo "Installing $package_path extension modules ..."
        process_dylibs $PYTHON_XCFRAMEWORK_PATH $package_path
    done
}
