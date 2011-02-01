#--  -*- mode: ruby; encoding: utf-8 -*-
# Copyright: Copyright (c) 2011 RightScale, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# 'Software'), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

Then /^the logs should show a \"([^\"]*)\" user agent$/ do |ua|
  File.open("#{@tmpdir}/weblog.out").read.should =~ /\Alocalhost - - \[[^\]]*\] \"GET [^ ]+ HTTP\/1\.1\" \d+ \d+ \"-\" \"#{Regexp.escape(ua)}\"\n\Z/
end

Then /^the proxy should have been used$/ do
  File.open("#{@tmpdir}/proxy.out").read.should =~ /\Alocalhost - [^ ]+ \[[^\]]*\] \"GET #{Regexp.escape(@uri.to_s)} HTTP\/1\.1\" \d+ \d+ \"-\" \".*\"\n\Z/
end

Then /^the proxy should have been tunneled through$/ do
  File.open("#{@tmpdir}/proxy.out").read.should =~ /^localhost - [^ ]+ \[[^\]]*\] \"CONNECT #{Regexp.escape(@uri.host)}:#{Regexp.escape(@uri.port.to_s)} HTTP\/1\.1\" \d+ \d+ \"-\" \".*\"\n$/
end
