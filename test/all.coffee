fs = require 'fs'
path = require 'path'
temp = require 'temp'
zlib = require 'zlib'
wrench = require 'wrench'
{spawn} = require 'child_process'
{expect} = require 'chai'
{Blob, Tree, Commit, Tag, Pack} = require '../src/js'
_zlib = require '../src/js/zlib'


createGitRepo = (done) ->
  temp.mkdir 'test-repo', (err, path) =>
    @path = path
    git = spawn 'git', ['init', path]
    git.on 'exit', ->
      done()

deleteGitRepo = -> wrench.rmdirSyncRecursive(@path, true)

captureOutput = (child, cb) ->
  out = []
  err = []
  child.stdout.setEncoding 'utf8'
  child.stderr.setEncoding 'utf8'
  child.stdout.on 'data', (chunk) ->
    out.push chunk
  child.stderr.on 'data', (chunk) ->
    err.push chunk
  child.stderr.on 'end', ->
    cb(out.join(''), err.join(''))
  
writeGitGraph = (repo, root, refName, cb) ->
  count = 0
  writeCb = ->
    count--
    cb() if !count
  head = root.serialize (serialized) ->
    count++
    writeGitObject(repo, serialized, writeCb)
  if refName
    if head.getType() == 'tag'
      refType = 'tags'
    else
      refType = 'heads'
    refPath = path.join(repo, '.git', 'refs', refType, refName)
    fs.writeFileSync(refPath, head.getHash(), 'utf8')
      
writeGitObject = (repo, serialized, cb) ->
  hash = serialized.getHash()
  dir = path.join(repo, '.git', 'objects', hash.slice(0, 2))
  fs.mkdir dir, ->
    bufferPath = path.join(dir, hash.slice(2))
    bufferFile = fs.createWriteStream(bufferPath, mode: 0o444)
    deflate = zlib.createDeflate()
    deflate.pipe(bufferFile)
    bufferFile.on 'open', ->
      deflate.end(serialized.getData())
      if typeof cb == 'function' then bufferFile.on('close', cb)
    bufferFile.on 'error', (err) ->
      if typeof cb == 'function' then cb()

testObjects = ->
  d1 = new Date 1000000000
  d2 = new Date 2000000000
  d3 = new Date 3000000000
  @b1 = new Blob 'test content\ntest content2\ntest content3\n'
  # this encode second blob as a delta of the first in packfiles
  @b2 = new Blob 'test content\ntest content2\ntest content3\nappend'
  @b3 = new Blob 'subdir test content\n'
  @t1 = new Tree {
    'file-under-tree': @b3
  }
  @t2 = new Tree {
    'some-file': @b1
    'some-file.txt': @b2
    'sub-directory.d': @t1
  }
  @t3 = new Tree {
    'another-file.txt': @b1
  }
  author = 'Git User <user@domain.com>'
  @c1 = new Commit @t1, author, null, d1, "Artificial commit 1"
  @c2 = new Commit @t2, author, null, d2, "Artificial commit 2", [@c1]
  @c3 = new Commit @t3, author, null, d3, "Artificial commit 3", [@c2]
  @tag = new Tag @c2, 'v0.0.1', author, d2, 'Tag second commit'

suite 'object serialization/deserialization', ->

  setup testObjects

  test 'blob', ->
    serialized = @b1.serialize()
    [blob, hash] = Blob.deserialize serialized.getData()
    expect(blob.contents.toString 'utf8').to.equal @b1.contents
    expect(hash).to.equal serialized.getHash()

  test 'tree', ->
    serialized = @t2.serialize()
    [tree, hash] = Tree.deserialize serialized.getData()
    expect(tree.children['some-file']).to.equal @b1.serialize()
      .getHash()
    expect(tree.children['some-file.txt']).to.equal @b2.serialize()
      .getHash()
    expect(tree.children['sub-directory.d']).to.equal @t1.serialize()
      .getHash()
    expect(hash).to.equal serialized.getHash()

  test 'commit', ->
    serialized = @c2.serialize()
    [commit, hash] = Commit.deserialize serialized.getData()
    expect(commit.tree).to.equal @t2.serialize().getHash()
    expect(commit.author).to.equal @c2.author
    expect(commit.date.getTime()).to.equal @c2.date.getTime()
    expect(commit.parents[0]).to.equal @c1.serialize().getHash()
    expect(commit.message).to.equal @c2.message
    expect(hash).to.equal serialized.getHash()

  test 'tag', ->
    serialized = @tag.serialize()
    [tag, hash] = Tag.deserialize serialized.getData()
    expect(tag.object).to.equal @c2.serialize().getHash()
    expect(tag.type).to.equal 'commit'
    expect(tag.name).to.equal @tag.name
    expect(tag.tagger).to.equal @tag.tagger
    expect(tag.date.getTime()).to.equal @tag.date.getTime()
    expect(hash).to.equal serialized.getHash()


suite 'git repository manipulation', ->

  suiteSetup createGitRepo

  suiteTeardown deleteGitRepo

  setup (done) ->
    testObjects.call @
    # write objects to the repository
    writeGitGraph @path, @c3, 'master', =>
      writeGitGraph @path, @tag, @tag.name, done

  test 'check repository integrity', (done) ->
    gitFsck = spawn 'git', ['fsck', '--strict'], cwd: @path
    captureOutput gitFsck, (stdout, stderr) ->
      expect(stdout).to.equal ''
      expect(stderr).to.equal ''
      done()

  test 'unpack objects in repository', (done) ->
    # delete all git objects written so git-unpack-objects will
    # actually unpack all objects
    objectsDir = path.join(@path, '.git', 'objects')
    find = spawn 'find', [objectsDir, '-type', 'f', '-delete']
    captureOutput find, (stdout, stderr) =>
      expect(stdout).to.equal ''
      expect(stderr).to.equal ''
      # git-fsck should report errors since there are broken refs
      gitFsck = spawn 'git', ['fsck', '--strict'], cwd: @path
      captureOutput gitFsck, (stdout, stderr) =>
        expect(stdout).to.equal ''
        expect(stderr).to.match /HEAD\:\s+invalid\s+sha1\s+pointer/
        # lets invoke git-unpack-objects passing our packed stream
        # so the repository will be repopulated
        pack = new Pack [@c3, @tag]
        gitUnpack = spawn 'git', ['unpack-objects', '-q', '--strict'],
          cwd: @path
        gitUnpack.stdin.end(pack.serialize())
        captureOutput gitUnpack, (stdout, stderr) =>
          expect(stdout).to.equal ''
          expect(stderr).to.equal ''
          # git-fsck should be happy again
          gitFsck = spawn 'git', ['fsck', '--strict'], cwd: @path
          captureOutput gitFsck, (stdout, stderr) =>
            expect(stdout).to.equal ''
            expect(stderr).to.equal ''
            done()


suite 'zlib binding', ->
  test 'deflate/inflate some data synchronously', ->
    data = new Buffer 30
    data.fill 'a'
    deflated = _zlib.deflate data
    mixedData = Buffer.concat [
      deflated
      new Buffer [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    ]
    # the following code is the reason why this zlib binding was needed:
    # packfiles contain deflated data mixed with other data, so to
    # advance properly in the packfile stream, we need to know how
    # many bytes each deflated sequence uses
    # we also to pass the original data size (which is available
    # on packfiles)so inflate can efficiently allocate memory to
    # hold output
    [inflated, bytesRead] = _zlib.inflate mixedData, data.length
    expect(inflated.toString()).to.equal data.toString()
    expect(bytesRead).to.equal deflated.length

