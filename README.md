# About

This shows how to dynamically provision Persistent Volumes using the [vSphere Cloud Provider](https://vmware.github.io/vsphere-storage-for-kubernetes/documentation/), [terraform](https://www.terraform.io/), and [the rke provider](https://registry.terraform.io/providers/rancher/rke) in a single-node Kubernetes instance.

The Persistent Volume will be dynamically created from a Persistent Volume Claim inside a vSphere Datastore.

The Persistent Volume will be dynamically (de)attached to the Virtual Machine as a SCSI disk.

**NB** There's a big caveat with terraform and vSphere Persistent Volumes: PVs are attached as a Virtual Machine Disks and when you try to use `terraform plan` again, these will appear as being modified outside of the terraform control; `terraform` is therefore [configured to ignore disks changes](https://github.com/hashicorp/terraform-provider-vsphere/issues/1028) to prevent it from modifying the VM configuration.

**NB** This uses the deprecated vSphere Cloud Provider driver (that's what RKE uses out-of-the-box). Newer installations should probably use the [vSphere CSI Driver](https://vsphere-csi-driver.sigs.k8s.io/).

**NB** This uses a VMFS Datastore. It does not uses vSAN.

## Usage (Ubuntu 20.04 host)

Install the [Ubuntu 20.04 VM template](https://github.com/rgl/ubuntu-vagrant).

Install `terraform`, `govc` and `kubectl`:

```bash
# install terraform.
wget https://releases.hashicorp.com/terraform/1.0.4/terraform_1.0.4_linux_amd64.zip
unzip terraform_1.0.4_linux_amd64.zip
sudo install terraform /usr/local/bin
rm terraform terraform_*_linux_amd64.zip
# install govc.
wget https://github.com/vmware/govmomi/releases/download/v0.26.0/govc_Linux_x86_64.tar.gz
tar xf govc_Linux_x86_64.tar.gz govc
sudo install govc /usr/local/bin/govc
rm govc govc_Linux_x86_64.tar.gz
# install kubectl.
kubectl_version='1.20.8'
wget -qO /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update
kubectl_package_version="$(apt-cache madison kubectl | awk "/$kubectl_version-/{print \$3}")"
sudo apt-get install -y "kubectl=$kubectl_package_version"
```

Save your environment details as a script that sets the terraform variables from environment variables, e.g.:

```bash
cat >secrets.sh <<'EOF'
export TF_VAR_vsphere_user='administrator@vsphere.local'
export TF_VAR_vsphere_password='password'
export TF_VAR_vsphere_server='vsphere.local'
export TF_VAR_vsphere_datacenter='Datacenter'
export TF_VAR_vsphere_compute_cluster='Cluster'
export TF_VAR_vsphere_datastore='Datastore'
export TF_VAR_vsphere_network='VM Network'
export TF_VAR_vsphere_folder='example'
export TF_VAR_vsphere_ubuntu_template='vagrant-templates/ubuntu-20.04-amd64-vsphere'
export GOVC_INSECURE='1'
export GOVC_URL="https://$TF_VAR_vsphere_server/sdk"
export GOVC_USERNAME="$TF_VAR_vsphere_user"
export GOVC_PASSWORD="$TF_VAR_vsphere_password"
EOF
```

**NB** You could also add these variables definitions into the `terraform.tfvars` file, but I find the environment variables more versatile as they can also be used from other tools, like govc.

Launch this example:

```bash
source secrets.sh
# see https://github.com/vmware/govmomi/blob/master/govc/USAGE.md
govc version
govc about
govc datacenter.info # list datacenters
govc find # find all managed objects
rm -f *.log kubeconfig.yaml
terraform init
terraform plan -out=tfplan
time terraform apply tfplan
# do another plan and you should verify that there are no changes.
terraform plan -out=tfplan
```

Test SSH access:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R "$(terraform output --raw ip)"
ssh "vagrant@$(terraform output --raw ip)"
exit
```

Test `kubectl` access:

```bash
terraform output --raw kubeconfig >kubeconfig.yaml
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes -o wide
```

Test creating a persistent workload:

```bash
# create a test StorageClass.
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: test
provisioner: kubernetes.io/vsphere-volume
parameters:
  datastore: $TF_VAR_vsphere_datastore
  diskformat: thin
  fstype: ext4
EOF
kubectl get storageclass
# create a test PersistentVolumeClaim.
# NB the vSphere Cloud Provider will create a folder named "kubevols"
#    inside the vSphere datastore. the actual k8s volumes .vmdk will be
#    stored as a, e.g., kubernetes-dynamic-pvc-5ed4b014-7db0-425e-97d4-8ff8dd0cd0e1.vmdk file.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test
spec:
  storageClassName: test
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF
# show the PVC status.
# NB this must not show any error or pending state.
kubectl describe pvc
# show the PVC status.
# NB this must not show any error or pending state.
# NB it should look something alike:
#       NAME   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
#       test   Bound    pvc-5ed4b014-7db0-425e-97d4-8ff8dd0cd0e1   5Gi        RWO            test           16m
kubectl get pvc
# show the corresponding PV (created automatically from the PVC).
kubectl get pv
# create the test Pod that uses the test PersistentVolumeClaim created PV.
# NB this will trigger the attachment of the PV volume as a new VM Hard Disk.
cat >test-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
    - name: web
      image: nginx
      ports:
        - name: web
          containerPort: 80
      volumeMounts:
        - mountPath: /usr/share/nginx/html
          name: web
  volumes:
    - name: web
      persistentVolumeClaim:
        claimName: test
EOF
kubectl apply -f test-pod.yaml
# see the pod status and wait for it be Running.
kubectl get pods -o wide
# show the current VM disks. you should see the sdb disk device and the
# corresponding disk UUID. sdb is the backing device of the pod volume.
ssh "vagrant@$(terraform output --raw ip)" -- lsblk -o KNAME,SIZE,TRAN,FSTYPE,UUID,LABEL,MODEL,SERIAL
# enter the pod and check the mount volume.
kubectl exec -it test -- /bin/bash
# show the mounts. you should see sdb mounted at /usr/share/nginx/html.
mount | grep nginx
# create the index.html file.
cat >/usr/share/nginx/html/index.html <<'EOF'
This is served from a Persistent Volume!
EOF
# check whether nginx is returning the expected html.
curl localhost
# exit the pod.
exit
# delete the test pod.
# NB this will trigger the removal of the PV volume from the VM.
kubectl delete pod/test
# list the PVs and check that the pv was not deleted.
kubectl get pv
# create a new pod instance.
kubectl apply -f test-pod.yaml
# see the pod status and wait for it be Running.
kubectl get pods -o wide
# enter the new pod and check whether it persisted the data.
kubectl exec -it test -- /bin/bash
# check whether nginx is returning the expected html.
curl localhost
# exit the pod.
exit
```

Destroy everything:

```bash
time terraform destroy --auto-approve
```

**NB** This will not delete the VMDKs that were used to store the Persistent Volumes. You have to manually delete them from the datastore `kubevols` folder (which is a PITA), or before `terraform destroy` manually delete the PVC with `kubectl delete pvc/test`.
