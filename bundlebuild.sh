#!/bin/bash
#
# the JBoss ON remote API via CLI will be used to create new bundle versions including the upload of new bundle files to the JON server.  The user of JON Server console will then perform the deployment of these new bundle versions to existing or new bundle destinations.  The bundle scanner and builder will use Java Scripting to interface with the JON API.
#
# variables for the CLI
CLI='/opt/jboss/jon/rhq-remoting-cli-4.4.0.JON312GA/bin/rhq-cli.sh'
# The manage bundles permission is the only permission available for a role (in JON 3.1.x). This single permission provides its recipient the ability to create, modify, delete, deploy, revert, or undeploy a bundle and its bundle versions.
OPTS='-u rhqadmin -p rhqadmin'
# directory to create dynamic scripts
APP_CLUSTER='isis'
SCRIPTS='/opt/jboss/jon/scripts'
REALM_ENV='qa'
RESTYPE='Linux'
RESPLUGIN='Platforms'
RESNAME='jon_server'
DRIFTNAME=$APP_CLUSTER'Drift'
DESC='drift after bundle deploy'
# base directory for deployment target to drift monitor, set some rules about what files or subdirectories to ignore (like log files), 
DEPLOYDIR="/www/${REALM_ENV}/"
DIRTYPE='fileSystem'
EXCLUDE='./logs/'
PATTERN=
MODE='normal'
INTERVAL='3600'
STAGEDIR="/stage/${REALM_ENV}/"

# create JON CLI with JS for Drift mgmt
driftDef() {
cat <<_EOF_

//set the resource type
var resType = ResourceTypeManager.getResourceTypeByNameAndPlugin("$RESTYPE","$RESPLUGIN");

//get the resource to associate with the drift definition
rcrit = ResourceCriteria()
rcrit.addFilterResourceTypeName("$RESTYPE")
rcrit.addFilterName("$RESNAME")
var resources = ResourceManager.findResourcesByCriteria(rcrit)
var res = resources.get(0)

//get the default template for the resource type
criteria = DriftDefinitionTemplateCriteria()
criteria.addFilterResourceTypeId(resType.id)
templates = DriftTemplateManager.findTemplatesByCriteria(criteria)
template = templates.get(0)

//create a new drift definition instance, based on the template
definition = template.createDefinition()

//set the drift definition configuration options
definition.resource = res
definition.name = '$DRIFTNAME'
definition.description = '$DESC'
definition.setAttached(false) // this is false so that template changes don't affect the definition

// this is set low to trigger an early initial detection run
definition.setInterval(30)
var basedir = new DriftDefinition.BaseDirectory(DriftConfigurationDefinition.BaseDirValueContext.valueOf('$DIRTYPE'),'$DEPLOYDIR')
definition.basedir = basedir

// there can be multiple exclude statements made, as desired
var f = new Filter("$EXCLUDE", "$PATTERN") // location, pattern
definition.addExclude(f)

//this defaults to normal, which means that any changes will
// trigger an alert. plannedChanges is the other option, which 
// disables alerting for drift changes.
definition.setDriftHandlingMode(DriftConfigurationDefinition.DriftHandlingMode.valueOf('$MODE'))

//apply the new definition to the resource
DriftManager.updateDriftDefinition(EntityContext.forResource(res.id),definition)

_EOF_
}

# makes a ZIP archive of the given drift base directory, and that makes the bundle archive.
#DEPLOYDIR='/www/'
SAMPLES='/opt/jboss/jon/rhq-remoting-cli-4.4.0.JON312GA/samples'
BUNDLEDESC=$APP_CLUSTER' bundle to remediate drift'
BUNDLENAME=$APP_CLUSTER'Bundle'
GROUPNAME='EAP ('$APP_CLUSTER'-'$REALM_ENV')'
CONTENT=$APP_CLUSTER'-content.zip'
# must dynamically increment this value
BVER='2.6'
BUNDLE="/tmp/${BUNDLENAME}/${BUNDLENAME}.zip"
VHOST_URL='isis-qa.naic.org'

#  creates the recipe (deploy.xml) which is used in the bundle archive
deploy() {
cat << _EOF_
<?xml version="1.0"?>
<project name="NAIC JBoss Deployments" default="main"
        xmlns:rhq="antlib:org.rhq.bundle">
    <rhq:bundle name="$BUNDLENAME" version="$BVER" description="$BUNDLEDESC">
        <rhq:deployment-unit name="drift" manageRootDir="false">
            <rhq:file name="${APP_CLUSTER}.zip" destinationFile="${APP_CLUSTER}/${APP_CLUSTER}.ear">
            </rhq:file>
            <rhq:file name="${VHOST_URL}.zip" destinationFile="http/${VHOST_URL}.zip">
            </rhq:file>
        </rhq:deployment-unit>
    </rhq:bundle>
<target name="main" />
</project>

_EOF_
}

# concatenates the bundles.js and util.js scripts together, and then appends the calls to create the bundle version and the bundle destination.
createBundle() {
cat $SAMPLES/util.js $SAMPLES/bundles.js
cat  << _EOF_

// set the location of the bundle archive
var path = '$BUNDLE'

// create the bundle version in JON
createBundleVersion(path)

// set all of the variables for the bundle destination
var destinationName = '$DEPLOYDIR'
var description = '$BUNDLEDESC'
var bundleName = '$BUNDLENAME'
var groupName = '$GROUPNAME'
var baseDirName = 'Root File System'
var deployDir = '$DEPLOYDIR'

// create the new destinition in JON
createBundleDestination(destinationName, description, bundleName, groupName, baseDirName, deployDir)

_EOF_
}

#pins the initial snapshot to the new drift definition.
snapshot() {
cat <<- _EOF_
//find the resource
rcrit = ResourceCriteria()
rcrit.addFilterResourceTypeName("$RESTYPE")
rcrit.addFilterName("$RESNAME")
var resources = ResourceManager.findResourcesByCriteria(rcrit)
var res = resources.get(0)

//find the new drift definition
criteria = DriftDefinitionCriteria()
criteria.addFilterName('$DRIFTNAME')
criteria.addFilterResourceIds(res.id)
def = DriftManager.findDriftDefinitionsByCriteria(criteria)
definition = def.get(0)
definition.setInterval($INTERVAL)

// it is necessary to redefine the complete configuration when you're 
// resetting the interval or the other values will be overwritten with default 
// or set to null
var basedir = new DriftDefinition.BaseDirectory(DriftConfigurationDefinition.BaseDirValueContext.valueOf('$DIRTYPE'),'$DEPLOYDIR')
definition.basedir = basedir
definition.name = '$DRIFTNAME'
// there can be multiple exclude statements made, as desired
var f = new Filter("$EXCLUDE", "$PATTERN") // location, pattern
definition.addExclude(f)
DriftManager.updateDriftDefinition(EntityContext.forResource(res.id),definition)

// pin to the initial snapshot, which is version 0
// this gets the most recent snapshot if that is the better version to use
// snap = DriftManager.getSnapshot(DriftSnapshotRequest(definition.id))
DriftManager.pinSnapshot(definition.id,0)
_EOF_
}

# fire all functions

# create the recipe file and then zip up the 
# drift base directory to make the bundle archive

echo "Creating the Deployable ..."

rm -rf /tmp/$BUNDLENAME
mkdir /tmp/$BUNDLENAME
# create Java and JBoss archive
# multiple deployment artifact support - A WAR that contains WARs at its root level is not a valid web application archive and the child WARs will not be read. Additionally, if the provisioning bundle contains multiple WARs and the exploded attribute of rhq:archive is set to true and the destination is a WAR directory, the result is that all three WARs will be merged into one. When deploying multiple web application archive (WAR) files you must do one of the following: 1) put each WAR into its own provisioning bundle, 2) put all the WARs into an enterprise application archive (EAR), 3) put all the WARs at the root of the bundle archive and specify a deployment destination that ends with .ear. For option #3, 3 WARs at its root level, specify the destination directory as my-app.ear instead of my-app.war and be sure that the exploded attribute of rhq:archive is set to false. For option #2, put the 3 WARs into a new archive named my-app.ear and place it into the bundle instead of the 3 separate WARs and set the exploded attribute of rhq:archive to true 
pushd $STAGEDIR/java/$APP_CLUSTER
zip -r /tmp/$BUNDLENAME/${APP_CLUSTER}.zip .
popd
# create HTTP static archive
pushd $STAGEDIR/http/$VHOST_URL
zip -r /tmp/$BUNDLENAME/${VHOST_URL}.zip .
popd
# create INI configuration archive
pushd $STAGEDIR/common//
zip -r /tmp/$BUNDLENAME/module.zip .
popd
# artifact file support - As a bundle recipe is simply a set of Ant tasks, there is nothing preventing a bundle from containing a tar.gz file and the Ant task actually executing a gunzip and untar commands to perform an installation of a local tar.gz file. 
pushd /tmp/$BUNDLENAME
deploy > /tmp/$BUNDLENAME/deploy.xml
zip -r $BUNDLE .
popd

# create the bundle from the recipe and archive
# and then create the bundle definition 

echo "Creating the Bundle ..."
createBundle > $SCRIPTS/createBundle.js
$CLI $OPTS -f $SCRIPTS/createBundle.js

# create the drift definition
# echo "Creating Drift Definition ..."
# driftDef > $SCRIPTS/driftDef.js
# $CLI $OPTS -f $SCRIPTS/driftDef.js

# sleep to allow the server to get the first snapshot
# this only sleeps for a minute, but it really depends on your environment
#echo "Allowing time for drift snapshot.  Please wait ..."
#sleep 1m

# apply drift - lay down audit of changes after this deployment via JON drift of the target resources (EAP or EWS)
# this pins the new snapshot to the new drift definition
# and then changes the drift interval to the longer, variable-specified

#echo "Creating Snapshot for Drift ..."
#snapshot > $SCRIPTS/snapshot.js
#$CLI $OPTS -f $SCRIPTS/snapshot.js

echo "Exiting Bundle Builder."
