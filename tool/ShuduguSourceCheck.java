import com.google.gson.*;
import org.jsoup.Jsoup;
import org.jsoup.nodes.*;
import org.jsoup.select.Elements;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.net.URI;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.util.*;

/** Live source-rule check using the frozen baseline's Jsoup 1.16.2.
 * Not the Android Legado runtime; outputs metadata/hashes, never chapter text.
 * Args: source.json output.json keyword
 */
public class ShuduguSourceCheck {
  static JsonObject source;
  static JsonArray requests = new JsonArray();
  static String rule(String group, String key) { return source.getAsJsonObject(group).get(key).getAsString(); }
  static String sha(byte[] bytes) throws Exception {
    StringBuilder out = new StringBuilder();
    for(byte b: MessageDigest.getInstance("SHA-256").digest(bytes)) out.append(String.format("%02x", b & 255));
    return out.toString();
  }
  static Document fetch(String url) throws Exception {
    URI uri = new URI(url);
    if(!"https".equals(uri.getScheme()) || !"www.shudugu.org".equals(uri.getHost())) throw new Exception("Unexpected host: " + url);
    uri = new URI(uri.getScheme(), uri.getAuthority(), uri.getPath(), uri.getQuery(), null);
    Path temp = Files.createTempFile("shudugu-check-", ".html");
    try {
      Process p = new ProcessBuilder("curl.exe", "--fail", "--silent", "--show-error", "--max-time", "25", "--output", temp.toString(), uri.toString()).inheritIO().start();
      if(p.waitFor()!=0) throw new Exception("Fetch failed: " + uri);
      byte[] bytes = Files.readAllBytes(temp);
      JsonObject item = new JsonObject(); item.addProperty("url", uri.toString()); item.addProperty("bytes", bytes.length); item.addProperty("sha256", sha(bytes)); requests.add(item);
      return Jsoup.parse(new String(bytes, StandardCharsets.UTF_8), uri.toString());
    } finally { Files.deleteIfExists(temp); }
  }
  static Elements list(Element context, String rule) {
    if(!rule.startsWith("@CSS:")) throw new IllegalArgumentException(rule);
    return context.select(rule.substring(5));
  }
  static String text(Element context, String rule) {
    String[] replacement = rule.split("##", -1);
    String selector = replacement[0].substring(5);
    int at = selector.lastIndexOf('@');
    String type = selector.substring(at+1);
    Elements elements = context.select(selector.substring(0, at));
    List<String> values = new ArrayList<>();
    for(Element e: elements) {
      String v = type.equals("text") ? e.text() : e.attr(type);
      if(!v.isEmpty() && (!type.equals("href") || !values.contains(v))) values.add(v);
    }
    String value = String.join("\n", values);
    if(replacement.length > 1) value = value.replaceAll(replacement[1], replacement.length > 2 ? replacement[2] : "");
    return value;
  }
  static String required(String v) throws Exception { if(v.trim().isEmpty()) throw new Exception("Empty required field"); return v; }
  static String resolve(String base, String relative) throws Exception { return new URI(base).resolve(required(relative)).toString(); }
  public static void main(String[] args) throws Exception {
    byte[] sourceBytes = Files.readAllBytes(Paths.get(args[0]));
    source = JsonParser.parseString(new String(sourceBytes, StandardCharsets.UTF_8)).getAsJsonArray().get(0).getAsJsonObject();
    JsonObject report = new JsonObject();
    report.addProperty("engine", "Jsoup 1.16.2 rule harness, not Android Legado");
    report.addProperty("time", java.time.OffsetDateTime.now().toString());
    report.addProperty("sourceSha256", sha(sourceBytes));
    report.add("requests", requests);
    try {
      String base = source.get("bookSourceUrl").getAsString();
      String searchUrl = resolve(base, source.get("searchUrl").getAsString().replace("{{key}}", URLEncoder.encode(args[2], "UTF-8")));
      Document search = fetch(searchUrl);
      Elements results = list(search, rule("ruleSearch", "bookList"));
      Element hit = null;
      for(Element item: results) if(text(item, rule("ruleSearch", "name")).equals(args[2])) { hit=item; break; }
      if(hit==null) throw new Exception("No exact search result");
      report.addProperty("searchResults", results.size());
      String bookUrl = resolve(searchUrl, text(hit, rule("ruleSearch", "bookUrl")));
      Document book = fetch(bookUrl);
      String title = required(text(book, rule("ruleBookInfo", "name")));
      if(!title.equals(args[2])) throw new Exception("Book title mismatch");
      report.addProperty("title", title);
      report.addProperty("author", required(text(book, rule("ruleBookInfo", "author"))));
      report.addProperty("introChars", required(text(book, rule("ruleBookInfo", "intro"))).length());
      report.addProperty("coverUrl", required(text(book, rule("ruleBookInfo", "coverUrl"))));
      String tocUrl = resolve(bookUrl, text(book, rule("ruleBookInfo", "tocUrl")));
      LinkedHashMap<String,String> chapters = new LinkedHashMap<>();
      Set<String> pages = new HashSet<>();
      while(!tocUrl.isEmpty()) {
        if(!pages.add(tocUrl) || pages.size()>20) throw new Exception("TOC pagination loop/cap");
        Document toc = fetch(tocUrl);
        Elements items = list(toc, rule("ruleToc", "chapterList"));
        if(items.isEmpty()) throw new Exception("Empty TOC page");
        for(Element item: items) {
          String url = resolve(tocUrl, text(item, rule("ruleToc", "chapterUrl")));
          if(chapters.put(url, required(text(item, rule("ruleToc", "chapterName"))))!=null) throw new Exception("Duplicate chapter URL");
        }
        String next = text(toc, rule("ruleToc", "nextTocUrl"));
        tocUrl = next.isEmpty() ? "" : resolve(tocUrl, next);
      }
      report.addProperty("tocPages", pages.size()); report.addProperty("chapters", chapters.size());
      JsonArray checked = new JsonArray(); report.add("checkedChapters", checked);
      for(Map.Entry<String,String> chapter: chapters.entrySet()) {
        if(checked.size()==2) break;
        String url = chapter.getKey(); StringBuilder body = new StringBuilder(); Set<String> seen=new HashSet<>();
        while(!url.isEmpty()) {
          if(!seen.add(url) || seen.size()>10) throw new Exception("Content pagination loop/cap");
          Document doc = fetch(url);
          body.append(required(text(doc, rule("ruleContent", "content")))).append('\n');
          String next=text(doc, rule("ruleContent", "nextContentUrl"));
          url=next.isEmpty()?"":resolve(url,next);
        }
        if(body.length()<300) throw new Exception("Implausibly short chapter");
        JsonObject c=new JsonObject(); c.addProperty("name",chapter.getValue()); c.addProperty("url",chapter.getKey()); c.addProperty("pages",seen.size()); c.addProperty("characters",body.length()); c.addProperty("sha256",sha(body.toString().getBytes(StandardCharsets.UTF_8))); checked.add(c);
      }
      if(checked.size()!=2) throw new Exception("Insufficient chapters");
      report.addProperty("verdict","pass");
    } catch(Exception error) {
      report.addProperty("verdict","fail"); report.addProperty("error",error.toString());
    }
    Files.write(Paths.get(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create().toJson(report).getBytes(StandardCharsets.UTF_8));
    System.out.println(report.get("verdict") + " requests=" + requests.size());
    if(!report.get("verdict").getAsString().equals("pass")) System.exit(1);
  }
}
