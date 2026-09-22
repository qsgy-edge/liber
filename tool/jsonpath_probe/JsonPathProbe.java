import com.jayway.jsonpath.JsonPath;
import com.jayway.jsonpath.ReadContext;

import java.util.Collection;
import java.util.List;
import java.util.Map;

/**
 * Prints what json-path 2.9.0 (the version the frozen
 * AnalyzeByJSonPath.kt wraps, gradle/libs.versions.toml:22) actually does with
 * one document and a list of rules.
 *
 * The ticket #44 lane needs the accepted/rejected grammar and the exact result
 * shape, not a remembered one. Each line is:
 *
 *   rule <TAB> ok|error <TAB> rendered result or exception
 *
 * where the rendering names the container types, because the difference between
 * a flat list of matches and a nested list matters for JsonSourceRules.values.
 */
public final class JsonPathProbe {

    private static final String DOCUMENT =
        "{"
      + "\"code\":0,"
      + "\"nul\":null,"
      + "\"nums\":[1,2,3,4],"
      + "\"data\":["
      +   "{\"hasContent\":1,\"content\":\"A\",\"title\":\"T1\",\"n\":5,\"s\":\"10\",\"tags\":[\"x\",\"y\"]},"
      +   "{\"hasContent\":0,\"content\":\"B\",\"title\":\"\",\"n\":10,\"s\":\"9\",\"tags\":[]},"
      +   "{\"hasContent\":\"1\",\"content\":\"C\",\"n\":15.5,\"tags\":[\"z\",\"y\"]},"
      +   "{\"content\":\"D\",\"n\":20,\"m\":{\"deep\":true}},"
      +   "{\"hasContent\":2,\"content\":\"E\",\"n\":null}"
      + "],"
      + "\"meta\":{\"className\":\"玄幻\",\"step\":1},"
      + "\"menus\":["
      +   "{\"title\":\"M1\",\"url\":\"/m1\",\"children\":[{\"title\":\"C1\"},{\"url\":\"/c2\"}]},"
      +   "{\"url\":\"/m2\"}"
      + "],"
      + "\"plain\":[\"p1\",\"p2\",\"p3\"]"
      + "}";

    /**
     * The corners the implementation is shaped around: what an existence check
     * does with a null value, what `exists` does outside the compiler-generated
     * form, and how a scan combines with a token that is not the leaf.
     */
    private static final String CORNER_DOCUMENT =
        "{"
      + "\"items\":["
      +   "{\"flag\":true,\"nulKey\":null,\"tags\":[\"x\",\"y\"],\"content\":\"A\"},"
      +   "{\"flag\":false,\"tags\":[\"y\"],\"content\":\"B\"},"
      +   "{\"nulKey\":null,\"content\":\"C\"},"
      +   "{\"flag\":true,\"tags\":[],\"content\":\"D\"}"
      + "],"
      + "\"nums\":[1,2,3],"
      + "\"plain\":[\"p1\",\"p2\"],"
      + "\"meta\":{\"className\":\"玄幻\"}"
      + "}";

    private static final String[] CORNER_RULES = {
        // Existence with a null value and with a boolean value.
        "$.items[?(@.nulKey)].content",
        "$.items[?(@.nulKey==null)].content",
        "$.items[?(@.nulKey empty true)].content",
        "$.items[?(@.flag)].content",
        "$.items[?(@.flag==true)].content",
        "$.items[?(@.flag exists true)].content",
        "$.items[?(@.flag exists false)].content",
        "$.items[?(@.flag exists 1)].content",
        "$.items[?(@.flag exists 'true')].content",
        "$.items[?(@.nulKey exists true)].content",

        // Comparison across the container and the number/string boundary.
        "$.items[?(@.tags == ['x','y'])].content",
        "$.items[?(@.tags in [['y']])].content",
        "$.items[?(@.nulKey != null)].content",
        "$.items[?(@.tags != null)].content",
        "$.items[?(@.content == 1)].content",

        // A scan whose target token is not the leaf.
        "$..[0]",
        "$..[0].content",
        "$..[1:2].content",
        "$..items.content",
        "$..items..content",
        "$..tags[0]",
        "$..*.content",

        // Slice spellings near the edge.
        "$.items[0:2:]",
        "$.items[ 1 : 3 ]",
        "$.items[+1:2]",
        "$.items[1:3 ]",
        "$.meta.className[1:2]",
        "$.items[0][1:2]",

        // A context token that is not the root document.
        "@.meta.className",
        "@.items[?(@.flag)].content",
    };
    

    private static final String[] RULES = {
        // The filter forms the used sources reach (briefing #44).
        "$.data[?(@.hasContent==1)].content",
        "$..menus..[?(@.title)]",
        ".[?(@.title)]",

        // Other spellings of those filters, and the operator set.
        "$.data[?(@.hasContent == 1)].content",
        "$.data[?(@.hasContent=='1')].content",
        "$.data[?(@.hasContent==\"1\")].content",
        "$.data[?(@.hasContent===1)].content",
        "$.data[?(@.n > 9)].content",
        "$.data[?(@.n < 9)].content",
        "$.data[?(@.s > 9)].content",
        "$.data[?(@.s >= '10')].content",
        "$.data[?(@.s < '10')].content",
        "$.data[?(@.n <= 10)].content",
        "$.data[?(@.n != 10)].content",
        "$.data[?(@.content =~ /^[ABC]$/)].content",
        "$.data[?(@.content =~ /^[ab]$/i)].content",
        "$.data[?(@.content =~ /A/)].content",
        "$.data[?(@.hasContent in [1,2])].content",
        "$.data[?(@.hasContent nin [1,2])].content",
        "$.data[?(@.hasContent in ['1'])].content",
        "$.data[?(@.title size 2)].content",
        "$.data[?(@.title empty false)].content",
        "$.data[?(@.title empty true)].content",
        "$.data[?(@.tags empty true)].content",
        "$.data[?(@.tags size 2)].content",
        "$.data[?(@.hasContent exists true)].content",
        "$.data[?(@.hasContent && @.n > 9)].content",
        "$.data[?(@.hasContent==1 || @.hasContent==2)].content",
        "$.data[?(!(@.hasContent==1))].content",
        "$.data[?(@.hasContent)]",
        "$.data[?(!@.hasContent)]",
        "$.data[?(@.missing)]",
        "$.data[?(@.missing==1)]",
        "$.data[?(@.hasContent==1 && @.missing)]",
        "$.data[?(@.m[?(@.deep)])].content",
        "$.data[?(@.m.deep)].content",
        "$.nums[?(@>2)]",
        "$.plain[?(@=='p2')]",
        "$.menus[?(@.title)]",
        "$.meta[?(@.className)]",
        "$.meta[?(@.className=='玄幻')]",
        "$.data[?(@.hasContent=1)].content",
        "$.data[?(@.hasContent)].content",
        "$..[?(@.title)]",
        "$..data[?(@.hasContent)]",
        "$.data[?(@.hasContent)].content",

        // Slices.
        "$.data[1:3].content",
        "$.data[0:2].content",
        "$.data[:2].content",
        "$.data[2:].content",
        "$.data[-2:].content",
        "$.data[:-2].content",
        "$.data[1:-1].content",
        "$.data[1:3:2]",
        "$.data[::2]",
        "$.data[::-1]",
        "$.data[:]",
        "$.data[10:20]",
        "$.data[7:]",
        "$.data[:99]",
        "$.data[3:1]",
        "$.data[-1]",
        "$.data[-99]",
        "$.data[0,2].content",
        "$.data[0, 2]",
        "$.data[1:3]",
        "$.data[1:3][0].content",
        "$.data[1:3].tags[0]",
        "$.meta[1:2]",
        "$.meta[0]",
        "$.meta.className[0]",
        "$.nul[1:2]",
        "$.nul[0]",
        "$.nul[?(@)]",
        "$.data[*].content",
        "$.plain[1:3]",
        "$.plain[-1]",
        "$..title",

        // Refusals the adapter must keep loud.
        "$.data[?(@.title.length() > 1)].content",
        "$.data[?(@.title =~ 'A')].content",
        "$.data[?(@.hasContent=1)]",
        "$.data[?(@.title contains 'T')].content",
        "$.data[?(@.tags subsetof ['x'])].content",
        "$.data[?(@.title == $..className)].content",
        "$.data[?]",
        "$.data[?()]",
        "$.data[1:3",
        "$.data[1:2:3:4]",
        "$.data[a:b]",
        "$.data[*",
        "$.data..",
        "$.data.",
        "$.data[?(@.title)]..",
        "$..",
        "$",
        "$.data['title']",
        "$.data[?(@.title)]&&$.meta",
        "$.data[?(@.title)||@.content].content",
    };

    private static String render(Object value) {
        if (value == null) return "null";
        if (value instanceof Map) {
            StringBuilder sb = new StringBuilder("Map{");
            boolean first = true;
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
                if (!first) sb.append(", ");
                first = false;
                sb.append(entry.getKey()).append('=').append(render(entry.getValue()));
            }
            return sb.append('}').toString();
        }
        if (value instanceof Collection) {
            StringBuilder sb = new StringBuilder("List[");
            boolean first = true;
            for (Object item : (Collection<?>) value) {
                if (!first) sb.append(", ");
                first = false;
                sb.append(render(item));
            }
            return sb.append(']').toString();
        }
        return value.getClass().getSimpleName() + '(' + value + ')';
    }


    /** Round 3: what a scan does when the token after `..` is not the leaf. */
    private static final String SCAN_DOCUMENT =
        "{\"items\":[{\"flag\":true,\"tags\":[\"x\",\"y\"],\"content\":\"A\"},"
      + "{\"flag\":false,\"tags\":[\"y\"],\"content\":\"B\"}],"
      + "\"nums\":[1,2,3],\"plain\":[\"p1\",\"p2\"],\"meta\":{\"className\":\"K\"}}";

    private static final String[] SCAN_RULES = {
        "$..*", "$..*.content", "$..[0]", "$..[0].content", "$..[1:2].content",
        "$..data[0]", "$..items[0]", "$..items[?(@.flag)]",
        "$..[?(@.flag)].content", "$..[?(@.flag)]", "$..items..content",
        "$..items.content", "$..*.tags", "$..tags[0]", "$..items[0].content",
        "$..nums[0]", "$..meta.className", "$..items[*].content",
    };

    /** Round 4: the `=~` full-match corners, and the number/string ones. */
    private static final String REGEX_DOCUMENT =
        "{\"x\":[{\"v\":\"ab\",\"k\":\"A\"},{\"v\":\"a\",\"k\":\"B\"},"
      + "{\"v\":\"p4\n\",\"k\":\"C\"},{\"v\":\"p4\",\"k\":\"D\"},"
      + "{\"v\":\"\",\"k\":\"E\"},{\"k\":\"F\"}],"
      + "\"n\":[10,15.5,\"10\"],\"tags\":[[\"y\"],[\"z\"],[]]}";

    private static final String[] REGEX_RULES = {
        "$.x[?(@.v =~ /a|ab/)].k",
        "$.x[?(@.v =~ /p4$/)].k",
        "$.x[?(@.v =~ /^$/)].k",
        "$.x[?(@.v =~ /AB/i)].k",
        "$.x[?(@.v =~ /a/)].k",
        "$.n[?(@ =~ /1[05]/)]",
        "$.tags[?(@ =~ /y/)]",
        "$.x[?(@.k =~ /^[ABC]$/)].k",
        "$.x[?(@.v =~ /x/m)]",
        "$.x[?(@.v =~ [0-9]+/)]",
    };

    private static void probe(String label, String document, String[] rules) {
        System.out.println("== " + label + " ==");
        ReadContext ctx;
        try {
            ctx = JsonPath.parse(document);
        } catch (RuntimeException e) {
            System.out.println("DOCUMENT PARSE FAILED " + e);
            return;
        }
        for (String rule : rules) {
            System.out.print(rule);
            System.out.print('\t');
            try {
                Object result = ctx.read(rule);
                System.out.println("ok\t" + render(result));
            } catch (Throwable e) {
                System.out.println(
                    "error\t" + e.getClass().getName() + ": " + e.getMessage());
            }
        }
    }

    public static void main(String[] args) {
        probe("main", DOCUMENT, RULES);
        probe("corners", CORNER_DOCUMENT, CORNER_RULES);
        probe("scan", SCAN_DOCUMENT, SCAN_RULES);
        probe("regex", REGEX_DOCUMENT, REGEX_RULES);
    }
}
