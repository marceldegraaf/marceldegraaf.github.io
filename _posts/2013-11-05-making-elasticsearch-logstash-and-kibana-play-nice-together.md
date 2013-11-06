---
layout: post
title: Making Elasticsearch, Logstash, and Kibana play nicely together
---

As [previously mentioned][1] we are using Elasticsearch at Wakoopa, mainly as a storage backend for our application logs. We currently store about 12 GB of log data per day to Elasticsearch, which translates to roughly 12 million daily log entries. In this post I want to share with you how we set up this log processing system.

### Elasticsearch

In my [previous post][1] I've outlined how to install and configure Elasticsearch. One important thing to note is that recently the S3 storage gateway has been deprecated. We have changed our configuration to use the `local` gateway, using Elastic Block Storage volumes to store the indices. Make sure to have at least one master and one slave node online with this setup, otherwise your shards will not be replicated and you risk data loss in case your single Elasticsearch node goes down.

Another interesting point to make is that we have moved to another Elasticsearch management GUI. We were using Paramedic before but have recently switched to the excellent [ElasticHQ][2] plugin. See the Github repo and their website for more info. Installation is easy: run `plugin -install royrusso/elasticsearch-HQ` from your Elasticsearch `bin` folder and point your browser to `http://your-elasticsearch-host/_plugin/HQ`.

So, now that Elasticsearch is running, let's proceed with Logstash and Kibana.

### Logstash

[Logstash][4] (recently acquired by Elasticsearch) is an application that reads log files (and can tail them in real time as they grow), process each line in the file as desired, and outputs the processed line to a storage backend. In our case we are mostly intrested in Rails' application logs, Resque job logs, and some other custom log files.

The first step in getting Logstash to process a log file is to look at the log format. Logstash is capable of parsing all kinds of log formats. See the [grok][5] filter for a demonstration. However, the more complex this parsing gets, the higher the risk Logstash misinterprets something. Therefore we've chosen to put the responsibility for understandable logs in our applications and write our logs in Logstash format whenever possible.
For Rails the excellent [logstash-event][12] gem (part of Lograge) is an easy way to get Rails to write logs in Logstash format. For Resque we have written our own logging extension which we may open source in the near future.

If you cannot change the log format of a log file that you want Logstash to read, you should take a close look at the [grok][5] filter. You may be able to write a grok filter that makes your log file workable for Logstash.

For each of the log files you want Logstash to read, you should define an `input`. Logstash supports an enormous collection of inputs, varying from simple files to Redis, SQS, ZeroMQ, a Unix pipe, and many more. See the [documentation][6] for more details.

Once your inputs are defined you can define filters to be applied to the data Logstash reads. This is not mandatory, but as mentioned earlier you may need a `grok` filter here to process a log file that Logstash cannot read by itself.

The last thing to define is an `output`, or multiple outputs. Logstash supports even more outputs than inputs, varying from a file to JIRA, Librato Metrics, RabbitMQ, SQS, and lots more. See the [documentation][6] for more information.

You'll see that Logstash also supports three different `elasticsearch` outputs, and you may want to use that in your own Logstash configurations. If you do, than the Logstash part is done. Your log files should be processed and each line should end up in Elasticsearch.

We, however, have chosen to use [Redis][7] as a queue between all our Logstash collectors and Elasticsearch. That means we use the `redis` output on every server that has a Logstash client processing logs. This way we can still properly process log files if Elasticsearch happens to be down. Our operation already requires us to have a highly available Redis server, so we found it easier to piggy-back on that existing setup.

To get our log lines out of Redis and into Elasticsearch, we run a Logstash instance on our Elasticsearch master node as well. This instance is configured to use Redis as an input, and outputs to Elasticsearch with the `elasticsearch_http` output. Nothing fancy going on here.

Now that you've got your stuff in Elasticsearch, let's add Kibana to the mix.

### Kibana

[Kibana][8] is an AngularJS application that acts as a client on Elasticsearch. It can do more than just display and filter Logstash logs, but that is all we use it for. See their website for more information.

Installing Kibana is quite simple; it can be installed as an Elasticsearch plugin. To install the latest version download [this ZIP file][9] and extract it to a temporary folder on your Elasticsearch node. Then create a `kibana` directory in your Elasticsearch's `plugins` directory and move the extracted `kibana` directory there. Finally, rename the `kibana-latest` dir in `plugins/kibana` to `_site` so Elasticsearch properly loads the plugin in your browser. You should now be able to open Kibana with your browser on `http://your-elasticsearch-host/_plugin/kibana`.

### Memory Considerations

To make sure our Logstash indices don't consume all the Elasticsearch node's RAM, we use a nightly cron job on the master node to close indices older than two weeks. Simplified, the script run by cron boils down to this:

{% highlight ruby linenos %}
require 'tire'
require 'yaml'

CLOSE_THRESHOLD = Date.today - 14

indices = YAML.load(Tire::Configuration.client.get("#{Tire::Configuration.url}/_aliases").body).keys
logstash_indices = indices.select { |index| index =~ /logstash-\d{4}.\d{2}.\d{2}/ }

logstash_indices.each do |index|
  year, month, day = index.gsub('logstash-', '').split('.').map(&:to_i)
  date = Date.new(year, month, day)

  tire_index = Tire::Index.new(index)

  if date < CLOSE_THRESHOLD
    tire_index.close
  end
end
{% endhighlight %}

We're typically not interested in logs older than two weeks. If we are, we can easily re-open the relevant indices from the ElasticHQ GUI. The cron script will close them again automatically the next night.

### Closing Words

Using the above setup we are able to comfortably process and store about 12 GB of log data per day on two `m1.medium` EC2 instances and a few EBS volumes. Using Redis as a queue means we don't need to panic if one of the Elasticsearch nodes is temporarily unreachable.

If you want to know more about our setup, or need help getting your stack running: feel free to [send me an email][10] or ping me on Twitter [@marceldegraaf][11].


[1]: {% post_url 2013-06-07-elasticsearch-on-ec2-with-auto-discovery %}
[2]: https://github.com/royrusso/elasticsearch-HQ
[3]: http://www.elastichq.org/support_plugin.html
[4]: http://www.elasticsearch.org/overview/logstash
[5]: http://logstash.net/docs/1.2.2/filters/grok
[6]: http://logstash.net/docs/1.2.2/
[7]: http://redis.io
[8]: http://www.elasticsearch.org/overview/kibana
[9]: http://download.elasticsearch.org/kibana/kibana/kibana-latest.zip
[10]: mailto:mail@marceldegraaf.net
[11]: http://twitter.com/marceldegraaf
[12]: https://github.com/roidrage/lograge
