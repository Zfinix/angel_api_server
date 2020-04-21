import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';

class User extends Model {
  String username;
  String password;
}

void main() async {
  var app = Angel();
  var http = AngelHttp(app);
  app.get('/', (req, res) => res.write('Hello, world!'));
  app.get('/headers', (req, res) {
    req.headers.forEach((key, values) {
      res.write('$key=$values');
      res.writeln();
    });
  });

  app.post('/greet', (req, res) async {
    await req.parseBody();

    var name = req.bodyAsMap['name'] as String;

    if (name == null) {
      throw AngelHttpException.badRequest(message: 'Missing name.');
    } else {
      res.write('Hello, $name!');
    }
  });

  app
  ..get('/add/int:number', (req, res) => req.params['number'] * 3)
  ..get('/multiply/double:number', (req, res) => req.params['number'] * 5.0);

  await http.startServer('localhost', 3000);

  void stopServer() async {
    await http.close();
  }
}
