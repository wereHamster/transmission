#!/usr/bin/php
<?

define("transmissionhost", "localhost");
define("transmissionport", "9091");
define("transmissionlocation", "transmission/rpc");
define("transmissionrpc", "http://".transmissionhost.":".transmissionport."/".transmissionlocation);

define("downloadlocation", "/data2/Torrents/Download/");
define("completelocation", "/data2/Torrents/Complete/");

function get_transmission_session_id()
{
  $fp = @fsockopen(transmissionhost, transmissionport, $errno, $errstr, 30);
  
  if (!$fp)
  {
    throw new Exception("Can not connect to transmission: $errstr ($errno)");
  }
  
  $out = "GET /".transmissionlocation." HTTP/1.1\r\n";
  $out .= "Host: ".transmissionhost."\r\n";
  $out .= "Connection: Close\r\n\r\n";
  fwrite($fp, $out);
  $info = stream_get_contents($fp);
  fclose($fp);
  
  $info = explode("\r\n\r\n", $info);
  $info = explode("\r\n", $info[0]);
  
  $headers = array();
  foreach ($info as $i)
  {
    $i = explode(": ", $i);
    $headers[$i[0]] = $i[1];
  }
  
  return $headers["X-Transmission-Session-Id"];
}

try
{
  define("transmissionsessionid", get_transmission_session_id());
} catch (Exception $e)
{
  printf("   *** Exception: %s\n", $e->getMessage());
  exit();
}

function do_post_request($url, $data)
{
  $params = array();
  $params["http"] = array();
  $params["http"]["method"] = "POST";
  $params["http"]["content"] = $data;
  $params["http"]["header"] = "X-Transmission-Session-Id: ".transmissionsessionid."\r\n";
    
  $ctx = stream_context_create($params);
  $fp = @fopen($url, "rb", false, $ctx);
  if (!$fp)
  {
    throw new Exception("Problem with $url, $php_errormsg");
  }

  $response = @stream_get_contents($fp);
  if ($response === false)
  {
    throw new Exception("Problem reading data from $url, $php_errormsg");
  }

  return $response;
}

$request = array();
$request["method"] = "torrent-get";
$request["arguments"] = array();
$request["arguments"]["fields"] = array("id", "name", "doneDate", "haveValid", "totalSize");

try
{
  $reply = json_decode(do_post_request(transmissionrpc, json_encode($request)));
} catch (Exception $e)
{
  printf("   *** Exception: %s\n", $e->getMessage());
  exit();
}

$arr = $reply->arguments->torrents;

foreach ($arr as $tor)
{
  if ($tor->haveValid == $tor->totalSize)
  {
    printf("Torrent '%s' finished on %s\n", $tor->name, strftime("%Y-%b-%d %H:%M:%S", $tor->doneDate));
    rename(downloadlocation.$tor->name, completelocation.$tor->name);
    $request = array("method" => "torrent-remove", "arguments" => array("ids" => array($tor->id)));

    try
    {
      $reply = json_decode(do_post_request(transmissionrpc, json_encode($request)));
    } catch (Exception $e)
    {
      printf("   *** Exception: %s\n", $e->getMessage());
      exit();
    }

    if ($reply->result != "success")
    {
      printf("   *** Failed to remove torrent ***\n");
    }
  }
}

?>
