---
layout: post
title: Experimenting with CoreOS, confd, etcd, fleet, and CloudFormation
---

One of my jobs at [Wakoopa](https://wakoopa.com) is to manage our technical infrastructure, on top of Amazon Web
Services. And although all developers in our team share some of that responsibility, I'm usually the one to
implement and update our CloudFormation stacks and our Chef cookbooks, and investigate new developments in this
field.

Today I want to walk you through my experiments with CoreOS, confd, etcd, fleet, and CloudFormation. I'm very excited
about these tools and I hope to share that excitement with you :-).

All the code for these experiments is in [this repo](https://github.com/marceldegraaf/coreos-blogpost-code). If you want to comment on this
blog post, or you run into issues with the walkthrough below, please [email me](mailto:mail@marceldegraaf.net) or [ping me](https://twitter.com/marceldegraaf) on Twitter.

### Introduction

So, what are CoreOS, confd, etcd, fleet, and CloudFormation? Let me introduce them to you real quick:

- [**CoreOS**](https://coreos.com/) is a minimal Linux-based operating system aimed at large-scale server deployments. CoreOS is
  written with scalability and security in mind. Next to that it is stongly biased towards Docker: every
  process running on a CoreOS server should be running in a Docker container. CoreOS comes with Docker and etcd
  pre-installed.

- [**Docker**](https://docker.io/) is an abstraction layer on top of [LXC](http://en.wikipedia.org/wiki/LXC). It
  allows you to run processes in a pseudo-VM that boots extremely fast (under 1 second) and isolates all its
  resources.

- [**confd**](https://github.com/kelseyhightower/confd) is a configuration management tool built on top of **etcd**. Confd can watch certain keys in etcd,
  and update the related configuration files as soon as the key changes. After that, confd can reload or restart
  applications related to the updated configuration files. This allows you to automate configuration changes to
  all the servers in your cluster, and makes sure all services are always looking at the latest configuration.

- [**etcd**](https://github.com/coreos/etcd) is a highly available, distributed key/value store that is built to
  distribute configuration updates to all the servers in your cluster. Next to that it can be used for service
  discovery, or basically for any other distributed key/value based process that applies to your situation.

  [Read more](https://coreos.com/using-coreos/etcd/) about how etcd works.

- [**fleet**](https://coreos.com/using-coreos/systemd/) is a layer on top of [**systemd**](http://www.freedesktop.org/wiki/Software/systemd/), the well-known
  init system. Fleet basically lets you manage your services on any server in your cluster transparently, and
  gives you some convenient tools to inspect the state of your services.

- [**CloudFormation**](https://aws.amazon.com/cloudformation/) is part of the Amazon Web Services suite. It is a
  tool that automates setting up a full application stack. You describe all the AWS resources your stack needs in JSON
  format, and upload that JSON file to CloudFormation. CloudFormation inspects the JSON file and creates all the
  requested AWS resources in the right order. There are two great advantages to using CloudFormation over manually
  creating your AWS resources:

  * The JSON file that describes your stack can be managed by source control
  * Once you delete your stack all related resources are deleted automatically, leaving you with a nicely cleaned up AWS account

The big question is: can we make all these tools play nicely together? If we could, we would have a very
sturdy base environment that could be used to host applications of any kind, and scale virtually endlessly.

### Following along

For the rest of this blog post I assume you've got access to the `docker` and `fleetctl` commands, either on a
(Vagrant) virtual machine or on your workstation. Follow the respective guides with installation instructions for
your platform, and make sure you have an AWS account. Then return here to follow along with me :-).

### CloudFormation stack

Let's start with creating a CloudFormation stack, consisting of a few EC2 instances and a security group that
gives the instances access to each others **etcd** daemons. This security group will also give you access to each
of the instances via SSH.

I've used [this stack definition](https://github.com/marceldegraaf/coreos-blogpost-code/blob/master/stack.yml). As you can see it's in YAML format for readability. The JSON version is [here](https://github.com/marceldegraaf/coreos-blogpost-code/blob/master/stack.json).
If you update the YAML version of the stack, use this shell command to parse it into JSON, assuming you have
Ruby installed and your YAML file is called `stack.yml`:

{% highlight bash %}
ruby -r json -r yaml -e "yaml = YAML.load(File.read('./stack.yml')); print yaml.to_json" > stack.json
{% endhighlight %}

Sign in to the AWS dashboard, open the CloudFormation page and click **Create Stack**. Enter a name, select your
`stack.json` file, fill in the requested fields and launch your stack. You should see your stack being created on
the CloudFormation page, eventually reaching the `CREATE_COMPLETE` state. This means your stack is done.

You should now have a few EC2 instances running CoreOS, ready to do work for you.

**Note**: at the time of writing there [is a bug](https://github.com/coreos/bugs/issues/3) in CoreOS that causes your EC2 instance's disk space to not be
properly resized after booting. The workaround is to run this command on each of the EC2 instances in your fleet,
via SSH:

{% highlight bash %}
sudo btrfs filesystem resize 1:max /
{% endhighlight %}

### First steps

To control your cluster with **fleet**, you use the `fleetctl` command. As you can read [here](https://github.com/coreos/fleet/blob/master/Documentation/security.md),
fleet has no built-in security mechanism. If you want to use `fleetctl` from your workstation, you need to configure
fleet to use an SSH tunnel. I found that an easy way to do this is to configure the SSH user and private key in
`~/.ssh/config` and then export the `FLEETCTL_TUNNEL` variable on the command line. Like so:

{% highlight bash %}
Host coreos
  User     core
  HostName <ip-of-a-cluster-instance>
  IdentityFile ~/.ssh/your_aws_private_key.pem
{% endhighlight %}

And:

{% highlight bash %}
export FLEETCTL_TUNNEL=<ip-of-a-cluster-instance>
{% endhighlight %}

It doesn't matter which instance you use as the other end of your SSH tunnel, as long as you use the EC2 instance's
public IP address. Of course the IP address in your SSH config must be the same as what you export in the environment variable.

Once you've done this, the following command:

{% highlight bash %}
fleetctl list-machines
{% endhighlight %}

Should show you the servers in your cluster:

{% highlight bash %}
MACHINE     IP              METADATA
015a6f3a... 10.104.242.206  -
3588db25... 10.73.200.139   -
{% endhighlight %}

### "Hello World" with etcd (de)registration

The following code describes a "Hello World" service that runs an eternal `while` loop in a Docker container. It
does more than that though: before starting and before stopping the container, the application registers itself
with etcd. This is the code:

{% highlight ini linenos wrap %}
[Unit]
Description=Hello World
After=docker.service
Requires=docker.service

[Service]
ExecStartPre=/bin/bash -c "/usr/bin/etcdctl set /test/%m $(fleetctl list-machines | grep $(bootctl status | grep 'Boot ID' | awk '{print substr($3,0,8)}') | awk '{print $2}')"
ExecStart=/usr/bin/docker run --name test --rm busybox /bin/sh -c "while true; do echo Hello World; sleep 1; done"
ExecStop=/usr/bin/etcdctl rm /test/%m
ExecStop=/usr/bin/docker kill test
{% endhighlight %}

Let's go through that line by line:

1. The `[Unit]` header
2. A description for this unit
3. Tells systemd to start this unit after `docker.service`
4. Tells systemd that this unit needs `docker.service` to operate properly
5. An empty line ;-)
6. The `[Service]` header
7. `ExecStartPre` runs before the service is started. This line does some magic to retrieve the external IP from
the host machine, from `fleetctl`. However, the relevant code is: `/usr/bin/etcdctl set /test/%m`, where I set a
key in etcd. In systemd, `%m` gets expanded to the unique machine ID. The result of this operation is that there
is a key in etcd called `/test/<machine-id>` with the value `<machine-ip`. This is useful for the Sinatra and nginx
part below.
8. `ExecStart` starts the actual service. This is a vanilla Docker command.
9. The first `ExecStop` deregisters the `/test/<machine-id>` key from etcd
10. The second `ExecStop` kills the actual Docker container.

To run this service, save it to a file called `hello.service` and submit it to your fleet with `fleetctl`:

{% highlight bash %}
fleetctl submit hello.service
{% endhighlight %}

If you now call `fleetctl list-units`, you should see your service running:

{% highlight bash %}
UNIT            STATE   LOAD    ACTIVE  SUB     DESC        MACHINE
hello.service   loaded  loaded  active  running Hello World a2ada91b.../172.17.8.102
{% endhighlight %}

To see the output of the service, call `fleetctl journal hello`:

{% highlight bash %}
-- Logs begin at Thu 2014-04-24 13:18:12 UTC, end at Fri 2014-04-25 09:50:50 UTC. --
Apr 25 09:50:40 core-02 docker[7565]: Hello World
Apr 25 09:50:41 core-02 docker[7565]: Hello World
Apr 25 09:50:42 core-02 docker[7565]: Hello World
Apr 25 09:50:43 core-02 docker[7565]: Hello World
...
{% endhighlight %}

Note that `journal` accepts a `-f` flag, which streams the output of the service to your terminal in real time.
To see the status of the service, call `fleetctl status hello`:

{% highlight bash %}
● hello.service - Hello World
   Loaded: loaded (/run/systemd/system/hello.service; static)
   Active: active (running) since Fri 2014-04-25 09:49:33 UTC; 1min 57s ago
  Process: 7546 ExecStartPre=/bin/bash -c /usr/bin/etcdctl set /test/%m $(fleetctl list-machines | grep $(bootctl status | grep 'Boot ID' | awk '{print substr($3,0,8)}') | awk '{print $2}') (code=exited, status=0/SUCCESS)
 Main PID: 7565 (docker)
   CGroup: /system.slice/hello.service
           └─7565 /usr/bin/docker run --name test --rm busybox /bin/sh -c while true; do echo Hello World; sleep 1; done
{% endhighlight %}

Now that we've got a simple "Hello World" application running with etcd (de)registration, it's time to move on to
something interesting: multiple Sinatra services and an nginx proxy that automatically adds/removes upstream servers
based on the presence of the Sinatra services.

### Sinatra and etcd

For the purpose of this experiment I've created a very simple Docker container that runs an "Hello world" app in
[Sinatra](http://www.sinatrarb.com/). The image has been pushed to the Docker Index, so you can use it with
`docker pull marceldegraaf/sinatra`.

The inspiration for this example is the [***Fleet Example Deployment***](https://coreos.com/docs/launching-containers/launching/fleet-example-deployment/)
page in the CoreOS documentation.

To run this container on our cluster, we need to define a systemd service that will start Docker with this image.
This is the service definition. I've saved it to a file called `sinatra.service`:

{% highlight ini linenos %}
[Unit]
Description=sinatra

[Service]
ExecStartPre=/usr/bin/docker pull marceldegraaf/sinatra
ExecStart=/usr/bin/docker run --name sinatra-%i --rm -p %i:5000 -e PORT=5000 marceldegraaf/sinatra
ExecStartPost=/bin/bash -c "/usr/bin/etcdctl set /app/server/%i $(fleetctl list-machines | grep $(bootctl status | grep 'Boot ID' | awk '{print substr($3,0,8)}') | awk '{print $2}'):%i"
ExecStop=/usr/bin/docker kill sinatra-%i
ExecStopPost=/usr/bin/etcdctl rm /app/server/%i

[X-Fleet]
X-Conflicts=sinatra@%i.service
{% endhighlight %}

As you can see we use the `%i` specifier as a placeholder for the port number. This is used for a nice feature of systemd: if the service description filename contains an `@`, the part before the `@`
is available in the service file as `%p`. The part after the `@` is available as `%i`, which is what we're doing here. Now, you'll probably think: "how does this work,
as the service is saved to a file called `sinatra.service`, without an `@`?". The neat thing is that we can create an arbitrary amount of symlinks to this single
service file, each of the symlinks having a different port number after the `@` in the filename. So, in concreto, I made the following symlinks:

{% highlight bash %}
-rw-r--r--  1 mdg  staff  510 Apr 26 16:04 sinatra.service
lrwxr-xr-x  1 mdg  staff   15 Apr 26 15:21 sinatra@5000.service -> sinatra.service
lrwxr-xr-x  1 mdg  staff   15 Apr 26 14:56 sinatra@5001.service -> sinatra.service
{% endhighlight %}

As you can guess, this defines two Sinatra services: one available on port 5000 of the host, one on port 5001 of the host.
To start these services in your cluster, first submit them with `fleetctl`:

{% highlight bash %}
fleetctl submit sinatra@5000.service
fleetctl submit sinatra@5001.service
{% endhighlight %}

You should now see your Sinatra services running with `fleetctl list-units`.

As you can see we start a Docker container with the name `sinatra` (line 2), and forward port 5000 or 5001 on the Docker host to
port 5000 of the Docker container. This is where the Thin webserver is running the simple Sinatra app.

Note the `X-Conflicts` statement in the `[X-Fleet]` section (line 12). This tells fleet to run only one Sinatra service with the same port per
host machine.

On line 7 of the service file we register the Sinatra service with etcd. In this case, we write a key called `/app/server/<port>` with a value
of `<host-ip>:<port>`.

If you log in to one of your machines via SSH, you can verify if the Sinatra services have registered themselves
in etcd. `etcdctl ls --recursive /app/server` should list your two ports:

{% highlight bash %}
/app
/app/server
/app/server/5000
/app/server/5001
{% endhighlight %}

If you were to kill one of the Sinatra services (with `fleetctl destroy sinatra@<port>`) you would see that one entry
disappears from etcd. If you submit it again, it sould re-register itself. Quite neat!

The next step is to add Nginx to the mix, to act as a dynamic proxy in front of these Sinatra services.

### Nginx and etcd

Lets start with creating a simple nginx service that we'll start with `fleetctl`:

{% highlight ini linenos %}
[Unit]
Description=nginx

[Service]
ExecStartPre=/usr/bin/docker pull marceldegraaf/nginx
ExecStart=/bin/bash -c "/usr/bin/docker run --rm --name nginx -p 80:80 -e HOST_IP=$(ip address show docker0 | grep 'inet ' | awk '{gsub(/\/[0-9]{2}/, \"\"); print $2}') marceldegraaf/nginx"
ExecStop=/usr/bin/docker kill nginx

[X-Fleet]
X-Conflicts=nginx.service
{% endhighlight %}

Again we do some shell magic to set the `$HOST_IP` variable. We basically take the IP address of the `docker0` interface, as this is where the Docker
container can reach etcd. Normally you would be able to use the IP address `172.17.42.1` to reach the Docker host from within a container, but for some
reason this didn't work with Vagrant on my machine while testing. The solution above should work in any environment.

As you can see the container uses my `marceldegraaf/nginx` Docker repository. The source files for that repository are here. Before I walk you through
how the automated service discovery works, let's start the nginx service:

{% highlight bash %}
fleetctl submit nginx.service
{% endhighlight %}

The magic happens in `boot.sh`. This is where confd comes into play. When the container boots, it runs `boot.sh`, which does some
interesting things:

{% highlight bash %}
until confd -onetime -node $ETCD -config-file /etc/confd/conf.d/nginx.toml; do
  echo "[nginx] waiting for confd to refresh nginx.conf"
  sleep 5
done
{% endhighlight %}

This code runs an endless loop, waiting for confd to do an initial update of the `nginx.conf` template. It uses `nginx.toml` as the confd configuration
file. That file looks like this:

{% highlight ini linenos %}
[template]
keys        = [ "app/server" ]
owner       = "nginx"
mode        = "0644"
src         = "nginx.conf.tmpl"
dest        = "/etc/nginx/sites-enabled/app.conf"
check_cmd   = "/usr/sbin/nginx -t -c /etc/nginx/nginx.conf"
reload_cmd  = "/usr/sbin/service nginx reload"
{% endhighlight %}

This configuration file tells confd to keep an eye on the `/app/server` etcd key, which we've used above to register the Sinatra services on. If there is
an update to one of the watched keys, the `src` template is parsed again and stored to `dest`, and `reload_cmd` gets called. This effectively reloads nginx
to look at the currently active upstream Sinatra services.

Once confd has done the initial update of the `nginx.conf` file, `boot.sh` starts confd in the background with an interval of 10 seconds:

{% highlight bash %}
confd -interval 10 -node $ETCD -config-file /etc/confd/conf.d/nginx.toml &
{% endhighlight %}

Every 10 seconds confd will check if there have been changes to the `/app/server` etcd key. If so, it will trigger an update of the nginx configuration file
and reload nginx.

### The result

Now that you've followed all these steps, you should have two Sinatra and one nginx service running on your CoreOS cluster. If you SSH into the machine that runs
the nginx container, you should be able to reach the Sinatra containers through nginx with a simple `curl localhost`. This should output `Hello World!`. If you run
`fleetctl journal -f sinatra@5000` and `fleetctl journal -f sinatra@5001` in two separate terminals, you should see the requests throuh nginx coming in. You should also
be able to stop any of the Sinatra services with `fleetctl destroy sinatra@<port>`, and still be able to perform requests through the nginx container on the remaining Sinatra
service. Of course this will stop working once you destroy both of the running Sinatra services.

You should also be able to connect to the nginx service from within your normal web browser, using the hostname of the ELB that was created with your CloudFormation run. To
get this hostname, log in to the AWS console and open the "Load Balancers" section of the EC2 dashboard. Click the ELB called `CoreOS-CoreOSELB...` and copy/paste the "A Record"
hostname (next to "DNS Name" in the details panel of the ELB) to a new browser tab. That page should also show "Hello World!".

Note that you could now create symlinks to an arbitrary amount of additional Sinatra service files (e.g. `sinatra@5002.service`, `sinatra@5003.service`, ...). Starting
these additional services should automatically register them in etcd and add them to the collection of nginx upstream servers:

{% highlight bash %}
UNIT                  STATE   LOAD    ACTIVE  SUB      DESC     MACHINE
nginx.service         loaded  loaded  active  running  nginx    e70d20cf.../10.88.3.238
sinatra@5000.service  loaded  loaded  active  running  sinatra  17904170.../10.81.1.90
sinatra@5001.service  loaded  loaded  active  running  sinatra  17904170.../10.81.1.90
sinatra@5002.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5003.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5004.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5005.service  loaded  loaded  active  running  sinatra  17904170.../10.81.1.90
sinatra@5006.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5007.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5008.service  loaded  loaded  active  running  sinatra  17904170.../10.81.1.90
sinatra@5009.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
sinatra@5010.service  loaded  loaded  active  running  sinatra  e70d20cf.../10.88.3.238
{% endhighlight %}

### Conclusion

First of all: congratulations for making it this far! This was by far the longest blog post I've ever written, and researching all this stuff cost me considerably more
time than I had expected. It was worth it though, because I'm extremely impressed by CoreOS and the tooling ecosystem around it. I wouldn't be surprised if this is going to
be the next big step in setting up highly available and scalable web applications.

This would also be a good place to mention [Flynn](https://flynn.io) and [Deis](http://deis.io), two projects that aim to solve "the devops issue" in ways similar to what you've seen in this post.

Next up for me is trying out Mozilla's [heka](http://hekad.readthedocs.org/en/latest/index.html) for aggregated log collection, and Heroku's [buildpacks](https://devcenter.heroku.com/articles/buildpacks)
to compile and run a full-blown web application in a generic Docker container. I might even blog about this! ;-).
