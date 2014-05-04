---
layout: post
title: "CoreOS follow-up: Sinatra, Logstash, Elasticsearch, and Kibana"
---

In my [previous article](http://marceldegraaf.net/2014/04/24/experimenting-with-coreos-confd-etcd-fleet-and-cloudformation.html) I started to explore
CoreOS on CloudFormation. I was extremely impressed by the power of the tools in the CoreOS ecosystem, so I decided to take the experiment one step
further. By adding Logstash, Elasticsearch, and Kibana to the mix, we're moving towards a more production ready setup.

The complete source code for this article is [here](https://github.com/marceldegraaf/blog-coreos-2).

### Introduction

So, what are Logstash, Elasticsearch, and Kibana? Just like last time, let me give you a quick introduction:

- [**Logstash**](http://logstash.net/) is a tool for managing events and logs. Logstash acts as a central place to send all logging and events, and
  comes with a wide range of so-called "outputs" to store or process these events.

- [**Elasticsearch**](http://www.elasticsearch.org/) is a highly-available, scalable, data storage and search platform. It's a document store with powerful search functions built in.
  We use it at Wakoopa to store, process, and analyze the logging events of all our applications. We currently store about 10GB of log data per day in
  Elasticsearch.

- [**Kibana**](http://www.elasticsearch.org/overview/kibana) is a visualization tool built for Logstash data stored in Elasticsearch. It allows you to easily
  analyze, compare, and filter your log data and is an invaluable tool when troubleshooting issues in large-scale applications.

The goal for this article is to hook up these three technologies to the Nginx/Sinatra stack we built in the previous article. The idea is to let each Sinatra
container ship off its log files to the central Logstash agent with logstash-forwarder. The Logstash agent will store the events in Elasticsearch and the Kibana
plugin (on the Elasticsearch server) will allow us to analyze the data.

I chose to run logstash-forwarder on the Sinatra container over the standard Java-based Logstash agent, because I want the log collection to have a minimal
impact on the resource utilization of the container. Logstash-forwarder is written in Go and as such has a very low memory/CPU profile. It also starts almost
instantaneously, which means the Sinatra container boot time isn't impacted by the log collector.

Before going with logstash-forwarder I briefly looked at [Heka](http://heka-docs.readthedocs.org/en/latest/) and [hekad](http://hekad.readthedocs.org/en/latest/) but
I didn't manage to get that running properly. If you are using Heka in a Ruby/Rails environment I'm extremely interested to hear your experiences. Please get in touch!

### Following along

For the rest of this article I assume you've got access to the `docker` and `fleetctl` commands, either on a
(Vagrant) virtual machine or on your workstation. Follow the respective guides with installation instructions for
your platform. Also make sure to clone the [Github repo](https://github.com/marceldegraaf/blog-coreos-2) that contains all the source code belonging to
this article. Then return here to follow along with me :-).

### Setting up Elasticsearch

This is the easiest part. The Elasticsearch service has a pretty simple [Dockerfile](https://github.com/marceldegraaf/blog-coreos-2/blob/master/elasticsearch/Dockerfile) and a systemd unit that looks like this:

{% highlight ini linenos wrap %}
[Unit]
Description=elasticsearch

[Service]
EnvironmentFile=/etc/environment
ExecStartPre=/usr/bin/docker pull marceldegraaf/elasticsearch
ExecStart=/usr/bin/docker run --rm --name elasticsearch -p 9200:9200 -e HOST_IP=${COREOS_PUBLIC_IPV4} marceldegraaf/elasticsearch
ExecStartPost=/usr/bin/etcdctl set /elasticsearch/host ${COREOS_PUBLIC_IPV4}
ExecStop=/usr/bin/docker kill elasticsearch
ExecStopPost=/usr/bin/etcdctl rm /elasticsearch/host

[X-Fleet]
X-Conflicts=elasticsearch.service
{% endhighlight %}

As you can see we publish the IP address of the host that runs the Elasticsearch container to etcd, in the `/elasticsearch/host` key. This key will
be picked up by the Logstash agent later on.

Submit and start the unit with fleetctl:

{% highlight bash %}
fleetctl submit elasticsearch.service
fleetctl start elasticsearch.service
{% endhighlight %}

Once the unit has started, you should be able to open the Kopf plugin in your browser, to inspect the current state of the Elasticsearch cluster.
You can reach Kopf with `http://<elasticsearch-ip>:9200/_plugin/kopf/`. It looks like this:

![Kopf](http://i.marceldegraaf.net/kopf_20140502_161309.png)

### Setting up Logstash

The next step is to set up a central Logstash agent that will receive log events from the logstash-forwarder process(es) in the Sinatra container(s).
This is a bit more complicated, as the Lumberjack protocol (used by logstash-forwarder) requires you to use SSL. This means you need to create your
own SSL certificates and configure them properly in Logstash (and later in logstash-forwarder).

To solve this, the Logstash container creates a new SSL key pair every time it boots, and stores the new certificate and private key in etcd. Each
Sinatra container can then create a local copy of the certificate and the private key, and configure logstash-forwarder with it. This is
probably not the most elegant solution, but it serves its purpose for now. Feel free to spam me on [Twitter](https://twitter.com/marceldegraaf) or
[email](mailto:mail@marceldegraaf.net) with better solutions for this ;-).

The systemd unit for Logstash looks like this:

{% highlight ini linenos wrap %}
[Unit]
Description=logstash

[Service]
EnvironmentFile=/etc/environment
ExecStartPre=/usr/bin/docker pull marceldegraaf/logstash
ExecStart=/usr/bin/docker run --rm --name logstash -e HOST_IP=${COREOS_PUBLIC_IPV4} -p 10101:10101 marceldegraaf/logstash
ExecStartPost=/usr/bin/etcdctl set /logstash/host ${COREOS_PUBLIC_IPV4}
ExecStop=/usr/bin/docker kill logstash
ExecStopPost=/usr/bin/etcdctl rm --dir --recursive /logstash

[X-Fleet]
X-Conflicts=logstash.service
{% endhighlight %}

This is nothing really special. Just as with Elasticsearch, we register the IP address of Logstash in etcd, in the `/logstash/host` key. This is to make sure
logstash-forwarder in the Sinatra containers can find the running Logstash agent in the network.

More notable is the `boot.sh` script (full code [here](https://github.com/marceldegraaf/blog-coreos-2/blob/master/logstash/bin/boot.sh)) that gets run when the Docker container starts. These are the most interesting parts:

{% highlight bash linenos %}
# Loop until confd has updated the logstash config
until confd -onetime -node $ETCD -config-file /etc/confd/conf.d/logstash.toml; do
  echo "[logstash] waiting for confd to refresh logstash.conf (waiting for ElasticSearch to be available)"
  sleep 5
done

# Create a new SSL certificate
openssl req -x509 -batch -nodes -newkey rsa:2048 -keyout /opt/logstash/ssl/logstash-forwarder.key -out /opt/logstash/ssl/logstash-forwarder.crt

# Publish SSL cert/key to etcd
curl -L $ETCD/v2/keys/logstash/ssl_certificate -XPUT --data-urlencode value@/opt/logstash/ssl/logstash-forwarder.crt
curl -L $ETCD/v2/keys/logstash/ssl_private_key -XPUT --data-urlencode value@/opt/logstash/ssl/logstash-forwarder.key
{% endhighlight %}

As you can see we first enter an endless `until` loop that waits for the `/elasticsearch/host` etcd key to be available. Once this key is available, confd updates
the `logstash.conf` file, setting the hostname of Elasticsearch. Effectively, this also means the Logstash agent will not start before Elasticsearch is running
and `logstash.conf` has been updated. In a production environment you would probably not do this, but rather add a buffer between Logstash and Elasticsearch.
At Wakoopa we currently solve this with a Redis buffer (Logstash has built-in Redis inputs and outputs). This is to make sure that log events will still be stored
somewhere, even if Elasticsearch is down for a bit. However, in this article I assume Logstash will only run once Elasticsearch is up.

Next we create a new SSL certificate with a private key, using `openssl`, and store the two resulting files in etcd with `curl`. As you will see further on, these keys
will be downloaded from etcd in the `boot.sh` script of the Sinatra container, to configure logstash-forwarder with.

As usual, start the Logstash agent with fleetctl:

{% highlight bash %}
fleetctl submit logstash.service
fleetctl start logstash.service
{% endhighlight %}

Once Logstash is running we can move on to the Sinatra containers, where the actual log collection will happen.

### Preparing Sinatra

To make sure Sinatra writes its logs in a format that Logstash can understand, we use a custom `LogstashLogger` class:

{% highlight ruby linenos %}
class LogstashLogger < Rack::CommonLogger
  private

  def log(env, status, header, began_at)
    now    = Time.now
    length = extract_content_length(header)
    logger = @logger || env['rack.errors']

    json = {
      '@timestamp' => now.utc.iso8601,
      '@fields'    => {
        'method'   => env['REQUEST_METHOD'],
        'path'     => env['PATH_INFO'],
        'status'   => status.to_s[0..3],
        'size'     => length,
        'duration' => now - began_at,
      }
    }

    logger.puts(json.to_json)
  end
end
{% endhighlight %}

The fields in the `json` hash correspond to Logstash's format, so we dont need to do any grokking to store the events in Logstash. We include the logger in `app.rb` like this:

{% highlight ruby linenos %}
require_relative 'lib/logstash_logger'

configure do
  enable :logging

  file = File.new(File.join($ROOT, "sinatra.log"), 'a+')
  file.sync = true

  use LogstashLogger, file
end
{% endhighlight %}

As you can see we write a `sinatra.log` file to the root of the Sinatra application, which is `/opt/app` (see the relevant `ADD` line in the [Dockerfile](https://github.com/marceldegraaf/blog-coreos-2/blob/master/sinatra/Dockerfile)). This
is the file that logstash-forwarder will have to watch.

### Adding logstash-forwarder

To collect log events with logstash-forwarder we must add it to the Sinatra container, and make sure it runs in the background before Sinatra starts. It must
also be properly configured, which will be done by confd. These are the interesting parts of `boot.sh` (full codre [here](https://github.com/marceldegraaf/blog-coreos-2/blob/master/sinatra/bin/boot.sh)):

{% highlight bash linenos %}
# Update all logstash-forwarder templates
echo "[app] updating logstash-forwarder config files"
confd -onetime -node $ETCD

# Start logstash-forwarder and background it
logstash-forwarder -config /etc/logstash-forwarder.json &
{% endhighlight %}

We let confd run once (with the `-onetime` flag) to update the logstash-forwarder configuration files. As you can see we assume Logstash is already running and has already
pushed it's hostname and the SSL keys to etcd. This is a bit naive: normally one would create an init script for logstash-forwarder and let confd run in the background to keep an eye
on the `/logstash/*` key in etcd, and restart logstash-forwarder once those keys change. In this article I assume Logstash will stay up, and the contents of the `/logstash/*` keys
will not change.

The config file for logstash-forwarder is in JSON format, and (after confd has processed it) looks like this:

{% highlight json linenos %}
{
  "network": {
    "servers": [ "<logstash-host>:10101" ],
    "ssl certificate": "/opt/logstash/ssl/logstash-forwarder.crt",
    "ssl key": "/opt/logstash/ssl/logstash-forwarder.key",
    "ssl ca": "/opt/logstash/ssl/logstash-forwarder.crt",
    "timeout": 15
  },

  "files": [
    {
      "paths": [
        "/opt/app/sinatra.log"
      ],
      "fields": { "type": "syslog" }
    }
  ]
}
{% endhighlight %}

The SSL certificate and private key are created by confd with their respective values from etcd. Logstash-forwarder just assumes the files are there, and contain the correct content.

Installing logstash-forwarder on the Docker container was a bit painful. I'm working on a Mac, so building the logstash-forwarder binary on my local system means it
cannot be run on a Linux machine (or container). On the other hand I also don't want to install Go on the Docker container, just to build the logstash-forwarder binary. So, in the end
I just spun up a Digital Ocean droplet, installed Go, built logstash-forwarder there, and uploaded the built binary to S3. You can find it [here](http://files.marceldegraaf.net/logstash-forwarder).
It's also added to the Docker container in the [Dockerfile](https://github.com/marceldegraaf/blog-coreos-2/blob/master/sinatra/Dockerfile#L20).

When you run `file logstash-forwarder` it should show: `logstash-forwarder: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked (uses shared libs), not stripped`. If
you build the binary for the wrong architecture, Docker will throw an error when you start the binary, saying: `cannot execute binary file`.

Now that logstash-forwarder is ready, it's time to launch the Sinatra container to see what it does.

### All together now!

As usual, fire up the Sinatra container with fleetctl, using one of the symlinked unit files from the previous article:

{% highlight bash %}
fleetctl submit sinatra@5000.service
fleetctl start sinatra@5000.service
{% endhighlight %}

If you call `fleetctl journal -f sinatra@5000.service` immediately after starting the unit, you can follow the process of booting the container. To confirm logstash-forwarder is
running properly, you should see something like this:

{% highlight bash %}
Launching harvester on new file: /opt/app/sinatra.log
Loading client ssl certificate: /opt/logstash/ssl/logstash-forwarder.crt and /opt/logstash/ssl/logstash-forwarder.key
Starting harvester: /opt/app/sinatra.log
...
Setting trusted CA from file: /opt/logstash/ssl/logstash-forwarder.crt
Connecting to 172.17.8.101:10101 (172.17.8.101)
Connected to 172.17.8.101
{% endhighlight %}

To be able to actually open the "Hello World!" page of the Sinatra app, also start the nginx proxy container:

{% highlight bash %}
fleetctl submit nginx.service
fleetctl start nginx.service
{% endhighlight %}

Your `fleetctl list-units` should look like this:

{% highlight bash %}
UNIT                  LOAD    ACTIVE  SUB     DESC          MACHINE
elasticsearch.service loaded  active  running elasticsearch 98bb2d97.../172.17.8.102
logstash.service      loaded  active  running logstash      fed8c3f4.../172.17.8.101
nginx.service         loaded  active  running nginx         98bb2d97.../172.17.8.102
sinatra@5000.service  loaded  active  running sinatra       fed8c3f4.../172.17.8.101
{% endhighlight %}

If you open your browser and enter the IP address of the nginx service (in my case `172.17.8.102`) you should see "Hello World!". But, more interestingly, you should
also see a line like this in `fleetctl journal elasticsearch.service`:

{% highlight bash %}
[INFO ][cluster.metadata] [Madelyne Pryor] [logstash-2014.05.03] creating index, cause [auto(bulk api)], shards [5]/[1], mappings [_default_]
[INFO ][cluster.metadata] [Madelyne Pryor] [logstash-2014.05.03] update_mapping [syslog] (dynamic)
{% endhighlight %}

This means the first Logstash event was processed, and a new index was created for it in Elasticsearch. You should see this index being listed in the Kopf interface
of your Elasticsearch cluster as well.

If you now point your browser to `<elasticsearch-ip>:9200/_plugin/kibana3/index.html#/dashboard/file/logstash.json` you see the Kibana Logstash page, which should
look like this:

![Kibana](http://i.marceldegraaf.net/Kibana_3__Logstash_Search_20140503_121019.png)

The vertical green bar represents requests to your Sinatra application, and the table underneath the graph contains a detailed overview of each request. To
make this a bit more interesting, let's start up three more Sinatra containers (on ports 5001, 5002, and 5003) and use the Ruby script below to generate some load
on the containers:

{% highlight bash %}
fleetctl submit sinatra@5001.service
fleetctl submit sinatra@5002.service
fleetctl submit sinatra@5003.service
fleetctl start sinatra@5001.service
fleetctl start sinatra@5002.service
fleetctl start sinatra@5003.service
{% endhighlight %}

The benchmark script looks like this:

{% highlight ruby linenos %}
require "net/http"
require "uri"

while true do
  threads = []

  5.times do
    threads << Thread.new do
      Net::HTTP.get_response(URI.parse("http://172.17.8.102"))
    end
  end

  threads.join

  sleep rand(2)
end
{% endhighlight %}

Make sure to replace the IP address with the IP of your nginx service. If you start this script with `ruby ./benchmark.rb` and open Kibana in your browser, you should see
some more interesting data:

![Kibana](http://i.marceldegraaf.net/Kibana_3__Logstash_Search_20140502_161251.png)

### Conclusion

Using logstash-forwarder together with Logstash and Elasticsearch is a powerful way to aggregate all your application's log events with a minimal impact on the application
container itself. Logstash provides a very flexible input/output system, and we haven't even touched on the various filters that Logstash offers. In a production environment
you would also make more use of tags to distinguish between log events of your different applications. These tags can be used in Kibana to easily filter the events of a single
application, or even of a single container.

I'm not sure where to go from here. I have a few ideas for things I'd like to test, but if you have requests: please let me know via [Twitter](https://twitter.com/marceldegraaf).
Thanks for reading!
