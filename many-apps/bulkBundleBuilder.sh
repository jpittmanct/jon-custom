#!/bin/bash
#
# this is a wrapper script for the core functionality of automating JON tasks.
# core funtionality is automated by standard Javascript for the JON CLI.  those scripts are imbedded here for parameterization
# the JBoss ON remote API via CLI will be used to create new bundle versions including the upload of new bundle files to the JON server.  
# this script must be ran on the JON Server, or wherever it's dependencies are at, and pointed to the hostname the resolves to the JON Server's management console
# variables for the JON CLI
#
JON_HOME='/opt/jboss/jon/'
CLI="$JON_HOME/rhq-remoting-cli-4.4.0.JON312GA/bin/rhq-cli.sh"
# these scripts are imported as dependencies to this one
SCRIPTS="$JON_HOME/scripts"
SAMPLES="$JON_HOME/rhq-remoting-cli-4.4.0.JON312GA/samples"
# The manage bundles permission is the only permission available for a role (in JON 3.1.x). This single permission provides its recipient the ability to create, modify, delete, deploy, revert, or undeploy a bundle and its bundle versions.
JONSERVER="localhost"
USERNAME="rhqadmin"
PASSWORD="rhqadmin"
OPTS="-u $USERNAME -p $PASSWORD -s $JONSERVER"
# base directory for deployment target to drift monitor, set some rules about what files or subdirectories to ignore (like log files),
pushd '/stage'
declare -a REALM_ENV=`find . -maxdepth 1 -mindepth 1 -type d | sed -e 's/\.\///'`
popd
DIRTYPE='fileSystem'
STAGEDIR="/stage/${REALM_ENV}/"
pushd "$STAGEDIR/java"
declare -a APP_CLUSTERS=`find . -maxdepth 1 -mindepth 1 -type d | sed -e 's/\.\///'`
popd
pushd "$STAGEDIR/http"
declare -a VHOST_URLS=`find . -maxdepth 1 -mindepth 1 -type d | sed -e 's/\.\///'`
popd
# environment and resource variables
RESTYPE='Linux'
RESPLUGIN='Platforms'
RESNAME='jon_server'
# variables for drift
#DRIFTNAME="${APP_CLUSTER}Drift"
#DRIFTDESC='drift after bundle deploy'
#EXCLUDE='./logs/'
#PATTERN=
#MODE='normal'
#INTERVAL='3600'

#
# function declarations:

#  creates the recipe (deploy.xml) which is used in the bundle archive
writeDeploy() {

BVER='1'
cat << _EOF_
<?xml version="1.0"?>
<project name="NAIC JBoss Deployments" default="main"
        xmlns:rhq="antlib:org.rhq.bundle">
    <rhq:bundle name="${BUNDLENAME}" version="$BVER" description="${BUNDLEDESC}">
        <rhq:deployment-unit name="drift" manageRootDir="false">
            <rhq:archive name="${ARCHIVE}" exploded="true">
            </rhq:archive>
        </rhq:deployment-unit>
    </rhq:bundle>
<target name="main" />
</project>

_EOF_
}

# purges the Bundle by name so the repository doesn't fill up
# instead of catenating, you can also just load these dependencies with exec -f
purgeBundle() {

#
# must dynamically increment this value

cat $SAMPLES/util.js $SAMPLES/bundles.js
cat  << _EOF_

var bundleCrit = new BundleCriteria;
        bundleCrit.addFilterName("${BUNDLENAME}");
        var bundles = BundleManager.findBundlesByCriteria(bundleCrit);

        if (bundles.empty) {
                throw "No bundle called";
        } else { 
		BundleManager.deleteBundle(bundles.get(0).id)
	}

_EOF_
}

# concatenates the bundles.js and util.js scripts together, and then appends the calls to create the bundle version and the bundle destination.
# instead of catenating, you can also just load these dependencies with exec -f
createBundle() {
#
# variables for Bundles
# must dynamically increment this value
BVER='1'

cat $SAMPLES/util.js $SAMPLES/bundles.js
cat  << _EOF_

// set the location of the bundle archive
var path = '$BUNDLE'

// create the bundle version in JON
createBundleVersion(path)

// set all of the variables for the bundle destination
var destinationName = '${GROUPNAME}'
var description = '${BUNDLEDESC}'
var bundleName = '${BUNDLENAME}'
var groupName = '${GROUPNAME}'
var baseDirName = 'Root File System'
var deployDir = '$DEPLOYDIR'

var groupCrit = new ResourceGroupCriteria;
        groupCrit.addFilterName("${GROUPNAME}");
        var groups = ResourceGroupManager.findResourceGroupsByCriteria(groupCrit);
        if (groups.empty) {
                throw "No group called";
        }

// create the new destinition in JON
createBundleDestination(destinationName, description, bundleName, groupName, baseDirName, deployDir)

_EOF_
}

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
definition.description = '$DRIFTDESC'
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

# main, function calls

# makes a ZIP archive of the given staging directory, and that makes the bundle archive.
# create the recipe file and then zip up the

for APP_CLUSTER in ${APP_CLUSTERS} 
do
	BUNDLENAME="${APP_CLUSTER}"
	BUNDLEDESC="${APP_CLUSTER} bundle for deployment"
	BUNDLE="/tmp/${BUNDLENAME}/${BUNDLENAME}_Bundle.zip"
	GROUPNAME="EAP ($APP_CLUSTER-$REALM_ENV-jboss)"
	ARCHIVE="${APP_CLUSTER}.zip"
	DEPLOYDIR='/opt/jboss/eap/jboss-eap-6.1/standalone/'
	echo "Creating the Deployables for $APP_CLUSTER ..."
	rm -rf /tmp/${BUNDLENAME}
	mkdir /tmp/${BUNDLENAME}

# create Java and JBoss archive
# multiple deployment artifact support - A WAR that contains WARs at its root level is not a valid web application archive and the child WARs will not be read. Additionally, if the provisioning bundle contains multiple WARs and the exploded attribute of rhq:archive is set to true and the destination is a WAR directory, the result is that all three WARs will be merged into one. When deploying multiple web application archive (WAR) files you must do one of the following: 1) put each WAR into its own provisioning bundle, 2) put all the WARs into an enterprise application archive (EAR), 3) put all the WARs at the root of the bundle archive and specify a deployment destination that ends with .ear. For option #3, 3 WARs at its root level, specify the destination directory as my-app.ear instead of my-app.war and be sure that the exploded attribute of rhq:archive is set to false. For option #2, put the 3 WARs into a new archive named my-app.ear and place it into the bundle instead of the 3 separate WARs and set the exploded attribute of rhq:archive to true
#
	pushd $STAGEDIR/java/$APP_CLUSTER
	zip -r /tmp/${BUNDLENAME}/${ARCHIVE} .
	popd

# artifact file support - As a bundle recipe is simply a set of Ant tasks, there is nothing preventing a bundle from containing a tar.gz file and the Ant task actually executing a gunzip and untar commands to perform an installation of a local tar.gz file.
	pushd /tmp/${BUNDLENAME}
	writeDeploy > /tmp/${BUNDLENAME}/deploy.xml
	zip -r $BUNDLE .
	popd

# purge the previous bundle
	echo "Purging previous Bundle ${BUNDLENAME}..."
	purgeBundle > $SCRIPTS/purgeBundle.js
	$CLI $OPTS -f $SCRIPTS/purgeBundle.js

# create the bundle from the recipe and archive
# and then create the bundle definition
	echo "Creating the Bundle for $APP_CLUSTER ..."
	createBundle > $SCRIPTS/createBundle.js
	$CLI $OPTS -f $SCRIPTS/createBundle.js

# create the drift definition
	#echo "Creating Drift Definition ..."
	#driftDef > $SCRIPTS/driftDef.js
	#$CLI $OPTS -f $SCRIPTS/driftDef.js

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

done

for VHOST_URL in ${VHOST_URLS} 
do
	BUNDLENAME="${VHOST_URL}"
	BUNDLEDESC="${VHOST_URL} bundle for deployment"
	BUNDLE="/tmp/${BUNDLENAME}/${BUNDLENAME}_Bundle.zip"
	GROUPNAME='EWS ('$VHOST_URL')'
	ARCHIVE=${VHOST_URL}.zip
	DEPLOYDIR="/www/${REALM_ENV}/http/$VHOST_URL/"
	echo "Creating the Deployables for $VHOST_URL ..."
	rm -rf /tmp/${BUNDLENAME}
	mkdir /tmp/${BUNDLENAME}

# create HTTP static archive
	pushd $STAGEDIR/http/$VHOST_URL
	zip -r /tmp/${BUNDLENAME}/${ARCHIVE} .
	popd
# create INI configuration archive
	pushd $STAGEDIR/common/
	zip -r /tmp/${BUNDLENAME}/module.zip .
	popd
# artifact file support - As a bundle recipe is simply a set of Ant tasks, there is nothing preventing a bundle from containing a tar.gz file and the Ant task actually executing a gunzip and untar commands to perform an installation of a local tar.gz file.
	pushd /tmp/${BUNDLENAME}
	writeDeploy > /tmp/${BUNDLENAME}/deploy.xml
	zip -r $BUNDLE .
	popd

# purge the previous bundle
	echo "Purging previous Bundle ${BUNDLENAME}..."
	purgeBundle > $SCRIPTS/purgeBundle.js
	$CLI $OPTS -f $SCRIPTS/purgeBundle.js

# create the bundle from the recipe and archive
# and then create the bundle definition
	echo "Creating the Bundle for $VHOST_URL ..."
	createBundle > $SCRIPTS/createBundle.js
	$CLI $OPTS -f $SCRIPTS/createBundle.js

# create the drift definition
#echo "Creating Drift Definition ..."
#driftDef > $SCRIPTS/driftDef.js
#$CLI $OPTS -f $SCRIPTS/driftDef.js

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

done

echo "Exiting Bundle Builder."
#
# end of main
