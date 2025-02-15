# frozen_string_literal: true
class EadProcessor
  require 'zip'

  # calls all the methods
  def self.import_eads(args = {})
    process_files(args)
  end

  def self.import_updated_eads(args = {})
    process_updated_files(args)
  end

  # sets the url
  def self.client(args = {})
    args[:url] || ENV['ASPACE_EXPORT_URL'] || 'http://localhost/assets/ead_export/'
  end

  # Open web address with Nokogiri
  def self.page(args = {})
    Nokogiri::HTML(open(client(args)))
  end

  # open file and call extract
  def self.process_files(args={})
    for file_link in page(args).css('a')
      file_name = file_link.attributes['href'].value
      link = client(args) + file_name
      directory = File.basename(file_name, File.extname(file_name))
      ext = File.extname(file_name)
      next unless ext == '.zip'
      next unless should_process_file(args, directory)

      open(link, 'rb') do |file|
        directory = directory.parameterize.underscore
        extract_and_index(file, directory)
      end
    end
  end

  def self.process_updated_files(args={})
    for file_link in page(args).css('a')
      file_name = file_link.attributes['href'].value
      file_name.slice! client(args)
      repository = File.dirname(file_name)
      file = File.basename(file_name)
      ext = File.extname(file_name)
      next unless ext == '.xml'
      args = { ead: file, repository: repository }
      EadProcessor.index_single_ead(args)
    end
  end

  # unzip the file and call index
  def self.extract_and_index(file, directory)
    Zip::File.open(file) do |zip_file|
      zip_file.each do |f|
        path = "./data/#{directory}"
        FileUtils.mkdir_p path unless File.exist?(path)
        fpath = File.join(path, f.name)
        File.delete(fpath) if File.exist?(fpath)
        filename = File.basename(fpath)
        zip_file.extract(f, fpath)
        add_ead_to_db(filename, directory)
        add_last_indexed(filename, DateTime.now)
        EadProcessor.delay.index_file(fpath, directory)
      end
    end
  end

  # for indexing a single ead file
  # need to unzip parent and index only the file selected
  def self.index_single_ead(args = {})
    puts args
    repository = args[:repository]
    file_name = args[:ead]
    link = client(args) + "#{repository}/#{file_name}"
    directory = repository.parameterize.underscore
    path = "./data/#{directory}"
    Dir.mkdir(path) unless Dir.exist?(path)
    puts link
    download = open(link, 'rb')
    fpath = File.join(path, file_name)
    IO.copy_stream(download, fpath)
    filename = File.basename(fpath)
    add_last_indexed(filename, DateTime.now)
    EadProcessor.delay.index_file(fpath, repository)
  end

  # extract file
  def self.extract_file(file, directory)
    Zip::File.open(file) do |zip_file|
      zip_file.each do |f|
        path = "./data/#{directory}"
        FileUtils.mkdir_p path unless File.exist?(path)
        fpath = File.join(path, f.name)
        File.delete(fpath) if File.exist?(fpath)
        zip_file.extract(f, fpath)
      end
    end
  end

  # index a file
  def self.index_file(filename, repository)
    ENV['REPOSITORY_ID'] = repository
    ENV['FILE'] = filename
    solr_url = begin
      Blacklight.default_index.connection.base_uri
    rescue StandardError
      ENV['SOLR_URL'] || 'http://127.0.0.1:8983/solr/blacklight-core'
    end
    `bundle exec rake arclight:index`
  end

  # get list of zip files and ead contents to show on admin import page
  def self.get_repository_names(args = {})
    repositories = {}
    for repository in page(args).css('a')
      name = repository.attributes['href'].value
      link = client(args) + name
      ext = File.extname(name)
      key = File.basename(name, File.extname(name))
      next unless ext == '.zip'
      value = { name: repository.children.text }
      repositories[key] = value
      last_updated_at = DateTime.parse(repository.next_sibling.text)
      add_repository_to_db(key, value[:name], last_updated_at)
      eads = []
      if ext == '.zip'
        open(link, 'rb') do |file|
          eads = get_ead_names(file, key)
        end
      end
      repositories[key][:eads] = eads
    end
    return repositories
  end

  def self.add_repository_to_db(id, name, last_updated_at)
    Repository.where(repository_id: id).first_or_create do |repo|
      repo.name = name
      repo.last_updated_at = last_updated_at
    end
  end

  # get list of eads contained in zip file
  def self.get_ead_names(file, repository)
    eads = []
    Zip::File.open(file) do |zip_file|
      zip_file.each do |entry|
        if entry.file?
          eads << entry.name
          add_ead_to_db(entry.name, repository)
        end
      end
    end
    return eads
  end

  def self.add_ead_to_db(filename, repository_id)
    Ead.where(filename: filename).first_or_create do |ead|
      ead.repository = Repository.find_by(repository_id: repository_id)
    end
  end

  def self.add_last_indexed(filename, indexed_at)
    Ead.find_by(filename: filename)&.update_attributes(last_indexed_at: indexed_at)
  end

  def self.add_last_updated(filename, updated_at)
    Ead.find_by(filename: filename)&.update_attributes(last_updated_at: updated_at)
  end

  def self.get_updated_eads(args = {})
    for ead in page(args).css('a')
      name = ead.attributes['href'].value
      ext = File.extname(name)
      name = File.basename(name, File.extname(name))
      next unless ext == '.xml'
      ead_filename = name + ext
      ead_last_updated_at = DateTime.parse(ead.next_sibling.text)
      add_last_updated(ead_filename, ead_last_updated_at)
    end
  end

  # check if should process file
  # if args are nil, process all zip files
  # otherwise, only process the specified file
  def self.should_process_file(args, name)
    args[:files].nil? || args[:files].include?(name)
  end
end
