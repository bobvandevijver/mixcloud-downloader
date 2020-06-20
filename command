#!/usr/bin/env php
<?php
require __DIR__ . '/vendor/autoload.php';

use Symfony\Component\Console\Helper\ProgressBar;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\ConsoleOutput;
use Symfony\Component\Console\SingleCommandApplication;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\DomCrawler\Crawler;
use Symfony\Component\Filesystem\Filesystem;
use Symfony\Component\HttpClient\HttpClient;
use Symfony\Component\PropertyAccess\PropertyAccess;
use Symfony\Component\Validator\Constraints\Url;
use Symfony\Component\Validator\Validation;
use Symfony\Component\Validator\Validator\ValidatorInterface;

class DownloadInfo
{
  /** @var string */
  private $url;
  /** @var string */
  private $title;
  /** @var string */
  private $m4a;
  /** @var resource|bool */
  private $fileHandle = false;
  /** @var int|null */
  private $progress = NULL;

  public function __construct(string $url, string $title, string $m4a)
  {
    $this->url   = $url;
    $this->title = $title;
    $this->m4a   = $m4a;
  }

  public function getUrl(): string
  {
    return $this->url;
  }

  public function getTitle(): string
  {
    return $this->title;
  }

  public function getM4a(): string
  {
    return $this->m4a;
  }

  public function getFileHandle()
  {
    return $this->fileHandle;
  }

  public function setFileHandle($fileHandle): self
  {
    $this->fileHandle = $fileHandle;

    return $this;
  }

  public function getProgress(): ?int
  {
    return $this->progress;
  }

  public function setProgress(?int $progress): self
  {
    $this->progress = $progress;

    return $this;
  }
}

function fromApi(SymfonyStyle $console, ValidatorInterface $validator): array
{
  $toResolve = [];

  while (true) {
    if (!$user = trim($console->ask('What is the MixCloud user URL?', 'https://www.mixcloud.com/538dancedepartment'))) {
      continue;
    }


    if ($validator->validate($user, new Url())->count() !== 0) {
      $console->error(sprintf('Supplied user URL "%s" is invalid!', $user));
      continue;
    }

    break;
  }

  $apiUrl = str_replace('www.mixcloud.com', 'api.mixcloud.com', $user);
  $console->text('Retrieving information...');
  $response     = HttpClient::create()->request('GET', $apiUrl . '/feed/?limit=100');
  $propAccessor = PropertyAccess::createPropertyAccessorBuilder()
      ->enableExceptionOnInvalidIndex()
      ->getPropertyAccessor();
  $data         = $propAccessor->getValue(json_decode($response->getContent(), true), '[data]');
  if (!$data) {
    throw new RuntimeException('Failed to retrieve API data from MixCloud.');
  }
  $count = count($data);

  for ($i = 0; $i < $count; $i++) {
    $episode = $propAccessor->getValue($data[$i], '[cloudcasts][0]');
    $name    = $propAccessor->getValue($episode, '[name]');
    $url     = $propAccessor->getValue($episode, '[url]');

    $answer = $console->choice(
        sprintf('Do you want to add "%s" to the downloads?', $name),
        [
            'Yes',
            'No',
            'Stop adding',
        ], 0
    );

    if ($answer === 'Stop adding') {
      break;
    }

    if ($answer === 'Yes') {
      $toResolve[] = $url;
    }
  }

  return $toResolve;
}

function fromConsole(SymfonyStyle $console, ValidatorInterface $validator): array
{
  /** @var string[] $toResolve */
  $toResolve = [];

  while (true) {
    if (!$url = trim($console->ask('Which MixCloud file do you want to download? (leave empty to start download)'))) {
      break;
    }

    if ($validator->validate($url, new Url())->count() !== 0) {
      $console->error(sprintf('Supplied URL "%s" is invalid!', $url));
      continue;
    }

    if (array_key_exists($url, $toResolve)) {
      $console->warning('Supplied URL already added!');
      continue;
    }

    $toResolve[] = $url;
  }

  return $toResolve;
}

(new SingleCommandApplication())
    ->setName('Download from MixCloud') // Optional
    ->setVersion('1.0.0') // Optional
    ->addArgument('download-dir', InputArgument::OPTIONAL, 'Output directory', 'download')
    ->setCode(function (InputInterface $input, ConsoleOutput $output) {
      $console    = new SymfonyStyle($input, $output);
      $validator  = Validation::createValidator();
      $http       = HttpClient::create();
      $dir        = $input->getArgument('download-dir');
      $fileSystem = new Filesystem();
      $fileSystem->mkdir($dir);

      $console->title('MixCloud downloader!');
      $console->text(sprintf('We will download the results into "%s"', $dir));

      $fromApi = $console->confirm('Do you want to use the MixCloud API to select episodes?');

      $toResolve = $fromApi
          ? fromApi($console, $validator)
          : fromConsole($console, $validator);

      $count = count(array_keys($toResolve));
      if (0 === $count) {
        $console->error('No downloads entered, exiting!');

        return;
      }

      /** @var DownloadInfo[] $urls */
      $urls      = [];
      $files     = [];
      $responses = [];

      $console->section('Resolving downloads, please be patient...');
      $resolveTextSection     = $output->section();
      $resolveProgressSection = $output->section();
      $resolveProgress        = new ProgressBar($resolveProgressSection, count($toResolve));

      $idx = 0;
      foreach ($toResolve as $url) {
        $resolveProgress->setProgress($idx++);

        // Retrieve download information from dlmixcloud.com
        $dlUrl    = str_replace('www.mixcloud.com', 'www.dlmixcloud.com', $url);
        $response = $http->request('GET', $dlUrl);
        if ($response->getStatusCode() !== 200) {
          $console->warning([
              'Failed to retrieve download information for:',
              $url,
              'Skipping...',
          ]);
          continue;
        }

        // Resolve download
        try {
          $crawler = new Crawler($response->getContent());
          $title   = $crawler->filter('h1')->first()->text();
          $m4a     = $crawler->filter('#download_button')->first()->link()->getUri();
        } catch (Throwable $e) {
          $console->warning([
              'Failed to resolve download information for:',
              $url,
              'Skipping...',
          ]);
          continue;
        }
        $info = new DownloadInfo($url, $title, $m4a);

        // Start the download
        $resolveTextSection->writeln(sprintf('Starting download for "%s"', $info->getTitle()));
        if ($console->isDebug()) {
          $console->text(sprintf('      %s', $info->getM4a()));
        }

        // Test file
        $file = $dir . '/' . $info->getTitle() . '.m4a';
        if (in_array($file, $files)) {
          $console->warning([
              'Error creating file, as it is already used by this process.',
              'Skipping download.',
          ]);
          continue;
        }

        if ($fileSystem->exists($file)) {
          $fileSystem->remove($file);
        }
        if (false === ($fileHandle = @fopen($dir . '/' . $info->getTitle() . '.m4a', 'w'))) {
          $console->warning([
              sprintf('Could not open output file "%s".', $file),
              'Skipping download.',
          ]);
          continue;
        }

        $info
            ->setProgress(0)
            ->setFileHandle($fileHandle);

        $responses[] = $http->request('GET', $info->getM4a(), [
            'user_data'   => $info,
            'on_progress' => function (int $dlNow, int $dlSize, array $info): void {
              if ($dlSize > 0) {
                /** @var DownloadInfo $downloadInfo */
                $downloadInfo = $info['user_data'];
                $downloadInfo->setProgress(round(($dlNow / $dlSize) * 100));
              }
            },
        ]);

        $files[]    = $file;
        $urls[$url] = $info;
      }

      $resolveProgress->finish();
      $count = count(array_keys($urls));
      if ($count === 0) {
        $console->error('No downloads resolved, exiting!');

        return;
      }

      $console->newLine();
      $console->note('MixCloud limits the download speed, so this can take some time!');

      $downloadsStartedSection = $output->section();
      $downloadsStartedSection->writeln('Downloads running');
      $downloadsStartedProgress = new ProgressBar($downloadsStartedSection, count($responses));

      $totalProgressSection = $output->section();
      $totalProgressSection->writeln('');
      $totalProgressSection->writeln('Total progress');
      $totalProgress = new ProgressBar($totalProgressSection, 100);

      foreach ($http->stream($responses) as $response => $chunk) {
        if ($chunk->isFirst()) {
          $downloadsStartedProgress->advance();
        }

        /** @var DownloadInfo $info */
        $info = $response->getInfo('user_data');
        fwrite($info->getFileHandle(), $chunk->getContent());

        $progress = array_map(function (DownloadInfo $info) {
          return $info->getProgress();
        }, $urls);
        $totalProgress->setProgress(round(array_sum($progress) / count($progress)));

        if ($chunk->isLast()) {
          fclose($info->getFileHandle());
        }
      }

      $downloadsStartedProgress->finish();
      $totalProgress->finish();

      $console->newLine();
    })
    ->run();
