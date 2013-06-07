---
layout: post
title: Elasticsearch on EC2 with node auto-discovery
---

At Wakoopa we use Elasticsearch for a few of our applications, so we've set up a centralized Elasticsearch
cluster that is managed with Amazon CloudFormation and Chef.

For the uninitiated: Elasticsearch is a search engine that is built with high availability and horizontal scaling
in mind. Node auto-discovery is the process in which an Elasticsearch node (typically a single server) is added
to a cluster automatically.

To set up Elasticsearch on EC2, I followed [this excellent tutorial](http://www.elasticsearch.org/tutorials/elasticsearch-on-ec2/).
Most of the heavy lifting regarding EC2 (and auto-discovery through the AWS API) is done by the [elasticsearch-cloud-aws plugin](https://github.com/elasticsearch/elasticsearch-cloud-aws).
However, I had some difficulty getting node auto-discovery to work. At one point I had 3 EC2 instances running Elasticsearch, but
each of these nodes promoted itself to master because the other nodes could not be found.

After some googling it appeared that the `discovery.type`, `discovery.ec2.groups`, and `cloud.aws.region` configuration options are
the key to get this to work.

The `discovery.type` setting must be set to `ec2` to tell Elasticsearch to use the AWS API to find suitable EC2
instances that are Elasticsearch nodes. Suitable nodes then get added to the cluster automatically.

The `discovery.ec2.groups` setting tells Elasticsearch to limit the search for EC2 instances to a certain
EC2 Security Group. Without this setting, **all** running instances in your AWS account will be pinged to see
if the instance is an Elasticsearch node. For me this failed. To solve this, add all Elasticsearch nodes to
a Security Group and specify the name of the Security Group in this configuration setting. In our case this is
`elasticsearch`.

The `cloud.aws.region` further limits the search for instances, this time to a specific AWS region.

So, putting it all together, this is how our configuration looks:

{% highlight yaml %}
cluster:
  name: search.example.com

node:
  name: your-node-name # in our case this is set to the host IP with Chef

path:
  data: /mnt/elasticsearch/data
  logs: /mnt/elasticsearch/logs

discovery:
  type: ec2

  ec2:
    groups: elasticsearch

gateway:
  type: s3
  s3:
    bucket: your-bucket

cloud:
  aws:
    region: eu-west-1

index:
  number_of_shards: 6
{% endhighlight %}

**Bonus**: to view the status of all your nodes, install the amazing [Paramedic](https://github.com/karmi/elasticsearch-paramedic/) plugin.
It's an embedded Ember.js app that polls the status of your indeces and nodes, and visualizes their performance.
