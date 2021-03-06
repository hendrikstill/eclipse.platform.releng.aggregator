#!/usr/bin/env bash
# for releng local tests only. 
# based on master script to drive Eclipse Platform builds
# but for use only after one build succeeds, then "local" modifications made, and 
# rebuild desired. 
# must be called with an existing "env.shsource" file from the previous build.
# basically skips the first steps and does not "clean" or re-pull from git.

# this buildeclipse.shsource file is to ease local builds to override some variables. 
# It should not be used for production builds.
source buildeclipse.shsource 

RAWDATE=$( date +%s )

if [ $# -ne 1 ]; then
    echo USAGE: $0 env_file
    exit 1
fi

INITIAL_ENV_FILE=$1

if [ ! -r "$INITIAL_ENV_FILE" ]; then
    echo "$INITIAL_ENV_FILE" cannot be read
    echo USAGE: $0 env_file
    exit 1
fi

export SCRIPT_PATH="${BUILD_ROOT}/production"


source "${SCRIPT_PATH}/build-functions.shsource"

source "${INITIAL_ENV_FILE}"


cd $BUILD_ROOT

buildrc=0

# derived values


BUILD_ID=$(fn-build-id "$BUILD_TYPE" )
buildDirectory=$( fn-build-dir "$BUILD_ROOT" "$BUILD_ID" "$STREAM" )
if [[ -z "${buildDirectory}" ]]
then
    echo "PROGRAM ERROR: buildDirectory returned from fn-build-dir was empty"
    exit 1
fi
logsDirectory="${buildDirectory}/buildlogs"
mkdir -p "${logsDirectory}"
checkForErrorExit $? "Could not create buildlogs directory: ${logsDirectory}"

LOG=$buildDirectory/buildlogs/buildOutput.txt
#exec >>$LOG 2>&1

BUILD_PRETTY_DATE=$( date --date='@'$RAWDATE )
TIMESTAMP=$( date +%Y%m%d-%H%M --date='@'$RAWDATE )

# TRACE_OUTPUT is not normally used. But, it comes in handy for debugging
# when output from some functions can not be written to stdout or stderr 
# (due to the nature of the function ... it's "output" being its returned value).
# When needed for local debugging, usually more convenient to provide 
# a value relative to PWD in startup scripts. 
export TRACE_OUTPUT=${TRACE_OUTPUT:-$buildDirectory/buildlogs/trace_output.txt}
echo $BUILD_PRETTY_DATE > ${TRACE_OUTPUT}

# These files have variable/value pairs for this build, suitable for use in 
# shell scripts, PHP files, or as Ant (or Java) properties
export BUILD_ENV_FILE=${buildDirectory}/buildproperties.shsource
export BUILD_ENV_FILE_PHP=${buildDirectory}/buildproperties.php
export BUILD_ENV_FILE_PROP=${buildDirectory}/buildproperties.properties

gitCache=$( fn-git-cache "$BUILD_ROOT" "$BRANCH" )
aggDir=$( fn-git-dir "$gitCache" "$AGGREGATOR_REPO" )
export LOCAL_REPO="${BUILD_ROOT}"/localMavenRepo

export STREAMS_PATH="${aggDir}/streams"

BUILD_TYPE_NAME="Integration"
if [ "$BUILD_TYPE" = M ]; then
    BUILD_TYPE_NAME="Maintenance"
elif [ "$BUILD_TYPE" = N ]; then
    BUILD_TYPE_NAME="Nightly (HEAD)"
elif [ "$BUILD_TYPE" = S ]; then
    BUILD_TYPE_NAME="Stable (Milestone)"
fi

GET_AGGREGATOR_BUILD_LOG="${logsDirectory}/mb010_get-aggregator_output.txt"
TAG_BUILD_INPUT_LOG="${logsDirectory}/mb030_tag_build_input_output.txt"
POM_VERSION_UPDATE_BUILD_LOG="${logsDirectory}/mb050_pom-version-updater_output.txt"
RUN_MAVEN_BUILD_LOG="${logsDirectory}/mb060_run-maven-build_output.txt"

# These variables, from original env file, are re-written to BUILD_ENV_FILE, 
# with values for this build (some of them computed) partially for documentation, and 
# partially so this build can be re-ran or re-started using it, instead of 
# original env file, which would compute different values (in some cases).
# The function also writes into appropriate PHP files and Properties files.
# Init once, here at beginning, but don't close until much later since other functions
# may write variables at various points
fn-write-property-init
fn-write-property PATH
fn-write-property INITIAL_ENV_FILE
fn-write-property BUILD_ROOT
fn-write-property BRANCH
fn-write-property STREAM
fn-write-property BUILD_TYPE
fn-write-property TIMESTAMP
fn-write-property TMP_DIR
fn-write-property JAVA_HOME
fn-write-property MAVEN_OPTS
fn-write-property MAVEN_PATH
fn-write-property AGGREGATOR_REPO
fn-write-property BASEBUILDER_TAG
fn-write-property B_GIT_EMAIL
fn-write-property B_GIT_NAME
fn-write-property COMMITTER_ID
fn-write-property MVN_DEBUG
fn-write-property MVN_QUIET
fn-write-property SIGNING
fn-write-property REPO_AND_ACCESS
fn-write-property MAVEN_BREE
fn-write-property GIT_PUSH
fn-write-property LOCAL_REPO
fn-write-property INITIAL_ENV_FILE
fn-write-property SCRIPT_PATH
fn-write-property STREAMS_PATH
# any value of interest/usefulness can be added to BUILD_ENV_FILE
if [[ "${testbuildonly}" == "true" ]]
then
    fn-write-property testbuildonly
fi
fn-write-property BUILD_ENV_FILE
fn-write-property BUILD_ENV_FILE_PHP
fn-write-property BUILD_ENV_FILE_PROP
fn-write-property BUILD_ID
fn-write-property BUILD_PRETTY_DATE
fn-write-property BUILD_TYPE_NAME

echo "# Build ${BUILD_ID}, ${BUILD_PRETTY_DATE}" > ${buildDirectory}/directory.txt





$SCRIPT_PATH/pom-version-updater.sh $BUILD_ENV_FILE 2>&1 | tee ${POM_VERSION_UPDATE_BUILD_LOG}
# if file exists, pom update failed
if [[ -f "${buildDirectory}/buildFailed-pom-version-updater" ]]
then
    buildrc=1
    /bin/grep "\[ERROR\]" "${POM_VERSION_UPDATE_BUILD_LOG}" >> "${buildDirectory}/buildFailed-pom-version-updater"
    echo "BUILD FAILED. See ${POM_VERSION_UPDATE_BUILD_LOG}." 
    BUILD_FAILED=${POM_VERSION_UPDATE_BUILD_LOG}
    fn-write-property BUILD_FAILED
else
    # if updater failed, something fairly large is wrong, so no need to compile
    $SCRIPT_PATH/run-maven-build.sh $BUILD_ENV_FILE 2>&1 | tee ${RUN_MAVEN_BUILD_LOG}
    # if file exists, then run maven build failed.
    if [[ -f "${buildDirectory}/buildFailed-run-maven-build" ]]
    then
        buildrc=1
        /bin/grep "\[ERROR\]" "${RUN_MAVEN_BUILD_LOG}" >> "${buildDirectory}/buildFailed-run-maven-build"
        BUILD_FAILED=${RUN_MAVEN_BUILD_LOG}
        fn-write-property BUILD_FAILED
        # TODO: eventually put in more logic to "track" the failure, so
        # proper actions and emails can be sent. For example, we'd still want to 
        # publish what we have, but not start the tests.  
        echo "BUILD FAILED. See ${RUN_MAVEN_BUILD_LOG}." 
    else
        # if build run maven build failed, no need to gather parts
        $SCRIPT_PATH/gather-parts.sh $BUILD_ENV_FILE 2>&1 | tee $logsDirectory/mb070_gather-parts_output.txt
        checkForErrorExit $? "Error occurred during gather parts"
    fi 

fi 

$SCRIPT_PATH/publish-eclipse.sh $BUILD_ENV_FILE >$logsDirectory/mb080_publish-eclipse_output.txt
checkForErrorExit $? "Error occurred during publish-eclipse"

# We don't promote equinox if there was a build failure, and we should not even try to 
# create the site locally, because it depends heavily on having a valid repository to 
# work from. 
if [[ -z "${BUILD_FAILED}" ]] 
then
  $SCRIPT_PATH/publish-equinox.sh $BUILD_ENV_FILE >$logsDirectory/mb085_publish-equinox_output.txt
  checkForErrorExit $? "Error occurred during publish-equinox"
fi 

# if all ended well, put "promotion scripts" in known locations
$SCRIPT_PATH/promote-build.sh CBI $BUILD_ENV_FILE 2>&1 | tee $logsDirectory/mb090_promote-build_output.txt
checkForErrorExit $? "Error occurred during promote-build"

fn-write-property-close

# dump ALL environment variables in case its helpful in documenting or 
# debugging build results or differences between runs, especially on different machines
env 1>$logsDirectory/mb100_all-env-variables_output.txt

exit $buildrc
