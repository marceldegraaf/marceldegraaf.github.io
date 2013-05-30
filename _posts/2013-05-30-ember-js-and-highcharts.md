---
layout: post
title: Ember.js and Highcharts
---

For [Wakoopa](http://wakoopa.com) we're currently investigating the use of Ember.js for one of our products. This
post demonstrates how to integrate [Highcharts](http://www.highcharts.com/) into an Ember application.

The implementation consists of a few key parts:

- A graph config file that holds the Highcharts configuration
- A subclass of this graph config file for each type of graph (line, bar, ...)
- A graph controller that does the actual rendering with Highcharts
- An Ember view that wraps around the graph controller
- A subclass of this Ember view for each type of graph, to be used in your templates

The graph configuration:

{% highlight coffeescript %}
App.GraphConfig = Ember.Object.create
  chart: null
  renderToId: null
  chartType: null
  series: null
  categories: null

  initialize: ->
    chart =
      renderTo: @get('renderToId')
      type:     @get('chartType')

    xAxis =
      categories: @get('categories')

    title =
      text: @get('title')

    @set('chart', chart)
    @set('xAxis', xAxis)
    @set('title', title)

  credits:
    enabled: false

  colors: [ "#2f69bf", "#a2bf2f", "#bf5a2f", "#bfa22f", "#772fbf",
            "#bf2f2f", "#00337f", "#657f00", "#7f2600", "#7f6500" ]
{% endhighlight %}

As you can see we immediately `create` an Ember object here, that has a few properties and an `initialize` function.
It is in this `initialize` function that various parts of the configuration get set when the graph controller
is setting up the graph for rendering.

A subclass of this graph config that defines a line graph:

{% highlight coffeescript %}
App.LineGraphConfig = Ember.Object.extend App.GraphConfig,
  yAxis:
    title:
      text: null

  plotOptions:
    bar:
      animation: false
      borderWidth: 0
      shadow: false
      dataLabels:
        enabled: true
{% endhighlight %}

The graph controller:

{% highlight coffeescript %}
App.GraphController = Ember.ObjectController.extend
  graphConfig: (type) ->
    switch type
      when 'line' then App.LineGraphConfig

  graphType: (type) ->
    switch type
      when 'line' then 'line'

  render: (render_to, type, data, categories, title) ->
    graph     = @graphConfig(type).create()
    graphType = @graphType(type)

    graph.set('chartType',  graphType)
    graph.set('renderToId', render_to)
    graph.set('series',     data)
    graph.set('categories', categories)
    graph.set('title',      title)

    graph.initialize()

    new Highcharts.Chart(graph)
{% endhighlight %}

The `graphConfig` and `graphType` functions determine which configuration class and which type to use in the
`render` function.

Then there's the view, to be used in your templates:

{% highlight coffeescript %}
App.GraphView = Ember.View.extend
  tagName: 'div'
  classNames: [ 'highcharts' ]
  title: 'Graph'
  type: 'line'

  didInsertElement: ->
    graph = new App.GraphController()
    graph.render(@elementId, @type, @content, @categories, @title)
{% endhighlight %}

Lastly, a subclass of this `App.GraphView` to render a line graph:

{% highlight coffeescript %}
App.LineGraphView = App.GraphView.extend
  type: 'line'
{% endhighlight %}

To actually render a graph, call the `App.LineGraphView` in your template:

{% highlight html %}
  App.LineGraphView id=my-graph contentBinding=myData categoriesBinding=myCategories title="This is a graph"
{% endhighlight %}
