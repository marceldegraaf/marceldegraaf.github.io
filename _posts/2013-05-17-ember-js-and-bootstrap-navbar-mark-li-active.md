---
layout: post
title: Ember.js and Bootstrap navbar - how to mark an li as active
---

I've been experimenting with Ember.js quite a bit over the last few weeks
and so far it has been a very interesting experience. The documentation
seems to have improved lately but some things still require a bit of
Google-fu to get right.

One of the things that took me while to figure out was the right way to implement a Bootstrap navbar with Ember. The thing is: Ember has a nice `linkTo` helper that renders an `a` tag. It even automatically gets an `active` class when clicked. However, unfortunately, Bootstrap's navbar requires the encapsulating `li` (around the `a` tag) to get the `active` class.

The [best solution I found](http://stackoverflow.com/a/14501021/1728531) is surprisingly simple, as with most of these things in Ember. Credit goes to lesyk on StackOverflow.

This binds the `a` tag's `href` attribute to the `href` of the `li` tag above which results in a clickable link that sets the `active` class on the `li` instead of on the `a` tag.

The only thing you will have to make sure to do is to give your `a` tags an explicit `pointer` cursor in CSS for the `:hover` state:

{% highlight sass %}
a
  cursor: pointer
{% endhighlight %}

And that's it!
