---
layout: post
title: Elixir and Phoenix: continuous integration on Gitlab CI
---

Recently I was introduced to [Elixir](http://elixir-lang.org/) and [Phoenix](http://www.phoenixframework.org/) (thanks [@smeevil](https://twitter.com/smeevil)) and I've been playing around with that for the last few days. The functional programming takes some getting used to, but the quality of the tools and documentation are astounding and it's lots of fun to write a web application with Phoenix.

As a fun "real world" exercise I'm writing a simple web shop in Phoenix, as that touches on almost any aspect of web development: database interaction, frontend, backend, styling, image uploads, etcetera.

Of course I'm also writing tests for my mockup shop, and I thought it would be nice to try and hook these up to [Gitlab CI](https://about.gitlab.com/gitlab-ci/).

In this article you'll learn how to configure your Elixir/Phoenix project for continuous integration with Gitlab CI, including integration tests with [Hound](https://github.com/HashNuke/hound) and [PhantomJS](http://phantomjs.org/).

### Setting up Gitlab CI

To run your tests on Gitlab CI, you'll need a `.gitlab-ci.yml` file in the root of your project. You'll also need a Gitlab instance to run your tests on; [their documentation](http://doc.gitlab.com/ce/ci/) has all the details.

I'm using the [Docker runner](http://doc.gitlab.com/ce/ci/docker/using_docker_images.html) to run my tests locally. This is my `.gitlab-ci.yml`:

```yaml
image: "marceldegraaf/elixir"
services:
  - "postgres:latest"

variables:
  POSTGRES_DB: shop_test
  POSTGRES_USER: postgres
  POSTGRES_PASSWORD: ""
  MIX_ENV: test

before_script:
  - "phantomjs --wd --webdriver-logfile=/tmp/phantomjs.log > /dev/null 2>&1 &"
  - cp config/test.exs.ci config/test.exs
  - mix deps.get
  - mix ecto.create
  - mix ecto.migrate

stages:
  - test

job:
  stage: test
  script:
    - mix test
  artifacts:
    paths:
      - tmp/screenshots
  cache:
    paths:
      - "_build"
      - "deps"
```

The `marceldegraaf/elixir` image contains an Erlang VM with Elixir pre-installed, and also comes with PhantomJS to make testing with Hound possible.

As you can see, in the `before_script` section we first start PhantomJS in webdriver mode, and then prepare the application for running our tests. The actual test commands are in `job.script`; in this case I just run `mix test` to run my test files.

To run integration tests I'm using Hound, using the PhantomJS driver. I've added a `test/integration` folder to my Phoenix project. A simple home page integration test could look like this:

```elixir
defmodule Shop.HomePageTest do
  use ExUnit.Case
  use Hound.Helpers

  hound_session

  test "page title" do
    navigate_to "/"

    assert find_element(:tag, "h1") |> inner_html == "Welcome to our shop"
  end
end
```

To make sure Hound uses the PhantomJS webdriver, I've added this to my `config/test.exs` file:

```elixir
config :hound,
  driver: "phantomjs"
```

If you run these tests locally, make sure to start PhantomJS before running `mix test`, or Hound will trow errors for not being able to reach the webdriver.