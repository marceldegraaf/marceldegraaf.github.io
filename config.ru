use Rack::Static, :urls => ["/stylesheets", "/images", "/fonts"], :root => "public"

run lambda { |env|
  file = (env['PATH_INFO'] == '/huis' ? 'huis.html' : 'index.html')
  [200, { 'Content-Type' => 'text/html', 'Cache-Control' => 'public, max-age=86400' }, File.open("public/#{file}", File::RDONLY)]
}